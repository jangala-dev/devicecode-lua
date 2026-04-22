-- services/update/backends/mcu_component.lua
--
-- MCU update backend.
--
-- This backend builds on the generic component proxy backend, but overrides
-- stage() so the update artefact is pushed over fabric transfer before commit.
-- It also contributes an extra observer feed for transfer progress.

local M = {}

local function reconcile_component(component_state, job)
	local sw = type(component_state) == 'table' and component_state.software or nil
	local upd = type(component_state) == 'table' and component_state.updater or nil

	local version = type(sw) == 'table' and sw.version or nil
	local build = type(sw) == 'table' and sw.build or nil
	local boot_id = type(sw) == 'table' and sw.boot_id or nil
	local phase = type(upd) == 'table' and upd.state or nil
	local last_error = type(upd) == 'table' and upd.last_error or nil

	if phase == 'failed' or phase == 'rollback_detected' then
		return {
			done = true,
			success = false,
			version = version,
			build = build,
			boot_id = boot_id,
			error = tostring(last_error or phase),
			raw = component_state,
		}
	end

	if job.expected_version and version == job.expected_version then
		local boot_changed = (
			job.pre_commit_boot_id ~= nil
			and boot_id ~= nil
			and boot_id ~= job.pre_commit_boot_id
		)
		if boot_changed or (phase == 'running' or phase == 'ready' or phase == 'idle' or phase == nil) then
			return {
				done = true,
				success = true,
				version = version,
				build = build,
				boot_id = boot_id,
				raw = component_state,
			}
		end
	end

	return {
		done = false,
		version = version,
		build = build,
		boot_id = boot_id,
		raw = component_state,
	}
end

function M.new(opts)
	opts = opts or {}

	local proxy = assert(opts.proxy_mod, 'proxy_mod required')
	local component = opts.component or 'mcu'
	local timeout_prepare = opts.timeout_prepare or 10.0
	local timeout_stage = opts.timeout_stage or 60.0
	local timeout_commit = opts.timeout_commit or 10.0

	local transfer = type(opts.transfer) == 'table' and opts.transfer or {}
	local link_id = transfer.link_id or 'cm5-uart-mcu'
	local receiver = transfer.receiver
	local transfer_timeout = transfer.timeout_s or timeout_stage

	local backend = proxy.new({
		component = component,
		artifact_retention = 'release',
		timeout_prepare = timeout_prepare,
		timeout_stage = timeout_stage,
		timeout_commit = timeout_commit,
		reconcile = reconcile_component,
	})

	local proxy_observe_specs = backend.observe_specs

	function backend:stage(conn, job, ctx)
		if type(job.artifact_ref) ~= 'string' or job.artifact_ref == '' then
			return nil, 'missing_artifact_ref'
		end

		local source, oerr = ctx.artifact_open(job.artifact_ref)
		if not source then
			return nil, oerr or 'artifact_open_failed'
		end

		local payload = {
			op = 'send_blob',
			link_id = link_id,
			source = source,
			meta = {
				kind = 'firmware',
				component = component,
				version = job.expected_version,
				job_id = job.job_id,
				size = type(source.size) == 'function' and source:size() or nil,
				checksum = type(source.checksum) == 'function' and source:checksum() or nil,
				metadata = job.metadata,
			},
		}
		if type(receiver) == 'table' then
			payload.receiver = receiver
		end

		local value, err = conn:call({ 'cmd', 'fabric', 'transfer' }, payload, { timeout = transfer_timeout })
		if value == nil then return nil, err end
		if type(value) ~= 'table' then value = { ok = true } end
		if value.artifact_retention == nil then
			value.artifact_retention = 'release'
		end
		value.staged = true
		return value, nil
	end

	function backend:observe_specs(component_cfg)
		local specs = proxy_observe_specs(self, component_cfg)

		local transfer_cfg = type(component_cfg) == 'table' and component_cfg.transfer or transfer
		local obs_link_id = type(transfer_cfg) == 'table' and transfer_cfg.link_id or link_id

		if type(obs_link_id) == 'string' and obs_link_id ~= '' then
			-- During active MCU staging, mirror retained fabric transfer progress
			-- into the job's public progress view.
			specs[#specs + 1] = {
				key = 'transfer:' .. component,
				topic = { 'state', 'fabric', 'link', obs_link_id, 'transfer' },
				on_event = function(ctx, _rec, ev)
					local active = ctx.state.active_job and ctx.state.store.jobs[ctx.state.active_job.job_id] or nil
					if not (active and active.component == component and active.state == 'staging') then return end
					if not (type(ev) == 'table' and ev.op == 'retain' and type(ev.payload) == 'table') then return end

					local status = ev.payload.status or {}
					local sent = tonumber(status.offset) or 0
					local total = tonumber(status.size) or nil
					local pct = (total and total > 0) and (sent * 100.0 / total) or nil

					active.runtime = type(active.runtime) == 'table' and active.runtime or {}
					active.runtime.progress = active.runtime.progress or {}
					active.runtime.progress.transfer = {
						sent = sent,
						total = total,
						pct = pct,
					}

					local tstate = tostring(status.state or '')
					if tstate == 'done' then
						active.stage = 'staged_on_mcu'
					elseif tstate ~= '' and tstate ~= 'idle' then
						active.stage = 'transferring_to_mcu'
					end

					ctx.publisher:publish_job_only(active)
				end,
			}
		end

		return specs
	end

	return backend
end

return M
