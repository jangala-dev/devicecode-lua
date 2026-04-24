-- services/update/backends/mcu_component.lua
--
-- MCU update backend.
--
-- This backend builds on the generic component proxy backend.  The device
-- service owns the component staging action, including any fabric transfer
-- details.  This backend owns only MCU-specific reconcile policy and transfer
-- progress observation for update job display.

local reconcile = require 'services.update.backends.component_reconcile'

local M = {}

local function reconcile_component(component_state, job)
	return reconcile.evaluate_component_state(component_state, job, {
		require_boot_change = true,
	})
end

function M.new(opts)
	opts = opts or {}

	local proxy = assert(opts.proxy_mod, 'proxy_mod required')
	local component = opts.component or 'mcu'
	local timeout_prepare = opts.timeout_prepare or 10.0
	local timeout_stage = opts.timeout_stage or 60.0
	local timeout_commit = opts.timeout_commit or 10.0

	-- transfer is retained only as an optional observer hint for this release.
	-- Staging transport lives in the device component action configuration.
	local transfer = type(opts.transfer) == 'table' and opts.transfer or {}
	local link_id = transfer.link_id or 'cm5-uart-mcu'

	local backend = proxy.new({
		component = component,
		artifact_retention = 'release',
		timeout_prepare = timeout_prepare,
		timeout_stage = timeout_stage,
		timeout_commit = timeout_commit,
		reconcile = reconcile_component,
	})

	local proxy_observe_specs = backend.observe_specs

	function backend:observe_specs(component_cfg)
		local specs = proxy_observe_specs(self, component_cfg)

		local transfer_cfg = type(component_cfg) == 'table' and component_cfg.transfer or transfer
		local obs_link_id = type(transfer_cfg) == 'table' and transfer_cfg.link_id or link_id

		if type(obs_link_id) == 'string' and obs_link_id ~= '' then
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
