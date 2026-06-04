-- services/update/backends/component.lua
--
-- Canonical component update backend.  It knows Device's curated component
-- state/capability surface only; it has no Fabric, UART or raw-member knowledge.

local fibers = require 'fibers'
local op     = require 'fibers.op'

local model  = require 'services.update.model'
local topics = require 'services.update.topics'

local M = {}
local Backend = {}
Backend.__index = Backend

local function copy(v) return model.deep_copy(v) end

local function component_of(self, job)
	return (type(job) == 'table' and job.component) or self._component
end

local function metadata_of(job)
	return type(job) == 'table' and type(job.metadata) == 'table' and job.metadata or {}
end

local function positive_int(v)
	local n = tonumber(v)
	if n and n > 0 and n == math.floor(n) then return n end
	return nil
end

local function transfer_chunk_size_after_prepare(self, job, prepared)
	local meta = metadata_of(job)
	local max_chunk_size = positive_int(type(prepared) == 'table' and prepared.max_chunk_size)
	local forced = positive_int(meta.transfer_chunk_raw)
	if forced then
		if max_chunk_size and forced > max_chunk_size then
			print('[update-mcu]', 'transfer_chunk_raw_override',
				'chunk_size=' .. tostring(forced),
				'max_chunk_size=' .. tostring(max_chunk_size))
		end
		return forced
	end
	local selected = positive_int(meta.chunk_size) or positive_int(self._chunk_size)
	if selected and max_chunk_size and selected > max_chunk_size then
		return max_chunk_size
	end
	return selected or max_chunk_size
end

local function artifact_record(job)
	if type(job) ~= 'table' then return nil end
	return job.artifact or job.artifact_snapshot or job.artifact_meta
end

local function artifact_ref(job)
	if type(job) ~= 'table' then return nil end
	local art = artifact_record(job)
	return job.artifact_ref
		or job.ref
		or (type(art) == 'table' and (art.artifact_ref or art.ref or art.id))
end

local function expected_image_id(job, ctx)
	local meta = metadata_of(job)
	local pf = ctx and ctx.preflight or nil
	local art = artifact_record(job)
	return job.expected_image_id
		or meta.expected_image_id
		or meta.image_id
		or (type(pf) == 'table' and pf.expected_image_id)
		or (type(pf) == 'table' and pf.image_id)
		or (type(art) == 'table' and (art.expected_image_id or art.image_id))
end

local function transfer_from(job, ctx)
	local stage = type(job) == 'table' and (job.stage_result or job.staged or job.stage) or nil
	local pf = ctx and ctx.preflight or nil
	local art = artifact_record(job)
	local t = type(stage) == 'table' and (stage.transfer or stage) or nil
	return {
		digest_alg = (t and t.digest_alg) or (pf and pf.digest_alg) or (art and art.digest_alg) or 'xxhash32',
		digest = (t and t.digest) or (pf and pf.digest) or (art and (art.digest or art.checksum)),
		size = (t and t.size) or (pf and pf.size) or (art and art.size),
	}
end

local function call_component_op(self, component, method, payload, opts)
	if type(self._conn) ~= 'table' or type(self._conn.call_op) ~= 'function' then
		return op.always(nil, 'component_backend_connection_required')
	end
	local target = topics.component_rpc(component, method)
	return self._conn:call_op(target, payload, opts or self._call_opts):wrap(function (reply, err)
		if reply == false then return nil, err or 'component_call_failed' end
		return reply, err
	end)
end


local function unwrap_scope_value(scope_op, label)
	return scope_op:wrap(function (st, report, value, err)
		if st == 'ok' then
			if value == nil then return nil, err or (label and (label .. '_failed')) or 'operation_failed' end
			return value, err
		end
		return nil, value or err or report or st or (label and (label .. '_failed')) or 'operation_failed'
	end)
end

local function validate_stage_reply(reply)
	if type(reply) ~= 'table' then
		return nil, 'invalid_stage_reply'
	end
	if reply.ok == false then
		return nil, reply.err or reply.error or reply.reason or 'component_stage_update_failed'
	end
	if reply.public_status ~= nil and reply.public_status ~= 'succeeded' then
		return nil, reply.err or reply.error or reply.reason or reply.public_status
	end
	return true, nil
end

local function commit_acceptance_payload(reply)
	if type(reply) ~= 'table' then return nil end
	if reply.accepted ~= nil then return reply end
	if type(reply.value) == 'table' and reply.value.accepted ~= nil then return reply.value end
	if type(reply.reply_payload) == 'table' and reply.reply_payload.accepted ~= nil then
		return reply.reply_payload
	end
	return nil
end

local function validate_commit_reply(reply)
	if type(reply) ~= 'table' then
		return nil, 'invalid_commit_reply'
	end
	if reply.ok == false then
		return nil, reply.err or reply.error or reply.reason or 'component_commit_update_failed'
	end
	if reply.public_status ~= nil and reply.public_status ~= 'succeeded' then
		return nil, reply.err or reply.error or reply.reason or reply.public_status
	end
	local accepted = commit_acceptance_payload(reply)
	if type(accepted) ~= 'table' then
		return nil, 'component_commit_acceptance_missing'
	end
	if accepted.accepted ~= true then
		return nil, accepted.err or accepted.error or accepted.reason or 'component_commit_rejected'
	end
	return accepted, nil
end

local function phase_error(prefix, err)
	if err == nil or err == '' then return prefix end
	return prefix .. ':' .. tostring(err)
end

local function print_prepare_diag(event, fields)
	local parts = { '[update-prepare]', 'ev', event }
	for _, key in ipairs({
		'component', 'job_id', 'expected_image_id', 'duration_ms', 'ok', 'err',
	}) do
		local v = fields and fields[key]
		if v ~= nil and v ~= '' then
			parts[#parts + 1] = key
			parts[#parts + 1] = tostring(v)
		end
	end
	print(table.concat(parts, ' '))
end

local function describe_artifact(artifact)
	if type(artifact) == 'table' and type(artifact.describe) == 'function' then
		local ok, rec = pcall(function () return artifact:describe() end)
		if ok and type(rec) == 'table' then return rec end
	end
	return type(artifact) == 'table' and artifact or nil
end

local function component_snapshot(snapshot, component)
	if type(snapshot) ~= 'table' then return nil end
	local by_id = snapshot.by_id or snapshot.components
	local rec = type(by_id) == 'table' and by_id[component] or nil
	if type(rec) == 'table' and type(rec.state) == 'table' then return rec.state end
	if type(rec) == 'table' then return rec end
	if snapshot.component == component then return snapshot.state or snapshot end
	return nil
end

local function component_record(snapshot, component)
	if type(snapshot) ~= 'table' then return nil end
	local by_id = snapshot.by_id or snapshot.components
	local rec = type(by_id) == 'table' and by_id[component] or nil
	if type(rec) == 'table' then return rec end
	if snapshot.component == component then return snapshot end
	return nil
end

local function state_from_record(rec)
	if type(rec) ~= 'table' then return nil end
	if type(rec.state) == 'table' then return rec.state end
	return rec
end

local function latest_component_record(self, component)
	local obs = self._observer
	if obs and type(obs.snapshot) == 'function' then
		return component_record(obs:snapshot(), component)
	end
	return nil
end

local function latest_component_state(self, component)
	return state_from_record(latest_component_record(self, component))
end

local function updater_state(state)
	if type(state) ~= 'table' then return nil end
	return state.update or state.updater
end

local MCU_CRITICAL_FACTS = { 'software', 'updater', 'health' }

local function fact_present(v)
	if type(v) == 'table' then return next(v) ~= nil end
	return v ~= nil
end

local function missing_mcu_critical_facts(state)
	local missing = {}
	state = type(state) == 'table' and state or {}
	if not fact_present(state.software) then
		missing[#missing + 1] = 'software'
	end
	if not fact_present(updater_state(state)) then
		missing[#missing + 1] = 'updater'
	end
	if not fact_present(state.health) then
		missing[#missing + 1] = 'health'
	end
	return missing
end

local function comma_join(items)
	local out = {}
	for i = 1, #(items or {}) do out[i] = tostring(items[i]) end
	return table.concat(out, ',')
end

local function require_component_boot_id(self, component)
	local state = latest_component_state(self, component)
	local sw = state and state.software or nil
	if type(sw) ~= 'table' or sw.boot_id == nil or sw.boot_id == '' then
		return nil, 'component_software_boot_id_unavailable'
	end
	return true, nil
end

local function critical_fact_fabric(state, fact)
	local cp = type(state) == 'table' and state.control_plane or nil
	local facts = type(cp) == 'table' and cp.facts or nil
	local rec = type(facts) == 'table' and facts[fact] or nil
	if type(rec) ~= 'table' then return nil end
	return type(rec.fabric) == 'table' and rec.fabric or nil
end

local function has_session_identity(fabric)
	if type(fabric) ~= 'table' then return false end
	if type(fabric.peer_sid) ~= 'string' or fabric.peer_sid == '' then return false end
	if fabric.session_generation == nil or fabric.session_generation == '' then return false end
	return true
end

local function require_matching_mcu_fact_sessions(state)
	local missing = {}
	local metas = {}
	for _, fact in ipairs(MCU_CRITICAL_FACTS) do
		local fabric = critical_fact_fabric(state, fact)
		if not has_session_identity(fabric) then
			missing[#missing + 1] = fact
		else
			metas[fact] = fabric
		end
	end
	if #missing > 0 then
		return nil, 'mcu_control_plane_not_ready:fact_origin_missing:' .. comma_join(missing)
	end

	local peer_sid, session_generation
	for _, fact in ipairs(MCU_CRITICAL_FACTS) do
		local fabric = metas[fact]
		if peer_sid == nil then
			peer_sid = fabric.peer_sid
			session_generation = fabric.session_generation
		elseif peer_sid ~= fabric.peer_sid or session_generation ~= fabric.session_generation then
			return nil, 'mcu_control_plane_not_ready:mixed_fact_sessions'
		end
	end

	local link_id, link_generation
	for _, fact in ipairs(MCU_CRITICAL_FACTS) do
		local fabric = metas[fact]
		if fabric.link_id ~= nil and fabric.link_id ~= '' then
			if link_id == nil then
				link_id = fabric.link_id
			elseif link_id ~= fabric.link_id then
				return nil, 'mcu_control_plane_not_ready:mixed_fact_links'
			end
		end
		if fabric.link_generation ~= nil and fabric.link_generation ~= '' then
			if link_generation == nil then
				link_generation = fabric.link_generation
			elseif link_generation ~= fabric.link_generation then
				return nil, 'mcu_control_plane_not_ready:mixed_fact_links'
			end
		end
	end

	return true, nil
end

local function require_update_admission(self, component)
	if component ~= 'mcu' then
		return require_component_boot_id(self, component)
	end
	local rec = latest_component_record(self, component)
	local state = state_from_record(rec)
	local missing = missing_mcu_critical_facts(state)
	if #missing > 0 then
		return nil, 'mcu_control_plane_not_ready:missing_critical_facts:' .. comma_join(missing)
	end
	local sw = state and state.software or nil
	if type(sw) ~= 'table' or sw.boot_id == nil or sw.boot_id == '' then
		return nil, 'mcu_control_plane_not_ready:software_boot_id_unavailable'
	end
	local actions = state and state.actions or nil
	if type(actions) ~= 'table' or actions['prepare-update'] ~= true then
		return nil, 'mcu_control_plane_not_ready:prepare_route_missing'
	end
	local cp = state and state.control_plane or nil
	local source = state and (state.source or (type(cp) == 'table' and cp.source)) or nil
	if type(source) == 'table' and source.reason ~= nil and source.reason ~= '' then
		return nil, 'mcu_control_plane_not_ready:' .. tostring(source.reason)
	end
	local session_ok, session_err = require_matching_mcu_fact_sessions(state)
	if session_ok ~= true then return nil, session_err end
	return true, nil
end

function Backend:stage_op(job, _ctx)
	return unwrap_scope_value(fibers.run_scope_op(function ()
		local component = component_of(self, job)
		local ready, ready_err = require_update_admission(self, component)
		if ready ~= true then return nil, ready_err end

		local ref = artifact_ref(job)
		if not ref then return nil, 'artifact_ref_required' end
		if not self._artifact_store or type(self._artifact_store.open_op) ~= 'function' then
			return nil, 'artifact_store_unavailable'
		end

		local artifact, aerr = fibers.perform(self._artifact_store:open_op(ref))
		if artifact == nil then return nil, aerr or 'artifact_open_failed' end
		local desc = describe_artifact(artifact) or {}
		local meta = type(desc.meta) == 'table' and desc.meta or desc.metadata or {}
		local image_id = expected_image_id(job, { preflight = desc })
			or meta.expected_image_id or meta.image_id

		local prepare_payload = {
			job_id = job.job_id,
			target = component,
			expected_image_id = image_id,
			metadata = metadata_of(job),
		}
		local prepare_started = fibers.now()
		print_prepare_diag('prepare_call_start', {
			component = component,
			job_id = job.job_id,
			expected_image_id = image_id,
		})
		local prepared, perr = fibers.perform(call_component_op(self, component, 'prepare-update', prepare_payload))
		local prepare_duration = math.floor(((fibers.now() - prepare_started) * 1000) + 0.5)
		print_prepare_diag('prepare_call_done', {
			component = component,
			job_id = job.job_id,
			expected_image_id = image_id,
			duration_ms = prepare_duration,
			ok = prepared ~= nil,
			err = perr,
		})
		if prepared == nil then return nil, phase_error('component_prepare_update_failed', perr) end

		local payload = {
			job_id = job.job_id,
			expected_image_id = image_id,
			artifact_ref = ref,
			size = desc.size,
			digest_alg = desc.digest_alg or 'xxhash32',
			digest = desc.digest or desc.checksum,
			chunk_size = transfer_chunk_size_after_prepare(self, job, prepared),
			format = meta.format or desc.format or 'dcmcu-v1',
			metadata = metadata_of(job),
		}
		local reply, err = fibers.perform(call_component_op(self, component, 'stage-update', payload, { timeout = false }))
		if reply == nil then return nil, phase_error('component_stage_update_failed', err) end
		local ok_reply, rerr = validate_stage_reply(reply)
		if ok_reply ~= true then return nil, rerr end
		return {
			staged = true,
			component = component,
			expected_image_id = image_id,
			preflight = {
				component = component,
				artifact_ref = desc.artifact_ref or desc.ref or ref,
				format = meta.format or desc.format or 'dcmcu-v1',
				expected_image_id = image_id,
				image_id = image_id,
				size = desc.size,
				digest_alg = desc.digest_alg or 'xxhash32',
				digest = desc.digest or desc.checksum,
				payload_sha256 = meta.payload_sha256 or desc.payload_sha256,
				metadata = copy(meta),
			},
			prepared = prepared,
			transfer = {
				digest_alg = payload.digest_alg,
				digest = payload.digest,
				size = payload.size,
			},
			reply = reply,
		}, nil
	end), 'component_stage')
end

function Backend:pre_commit_record_op(job, ctx)
	local component = component_of(self, job)
	local state = latest_component_state(self, component)
	local sw = state and state.software or nil
	if type(sw) ~= 'table' then return op.always(nil, 'component_software_state_unavailable') end
	if sw.boot_id == nil or sw.boot_id == '' then return op.always(nil, 'pre_commit_boot_id_required') end
	local transfer = transfer_from(job, ctx)
	return op.always({
		component = component,
		expected_image_id = expected_image_id(job, ctx),
		pre_commit_image_id = sw.image_id,
		pre_commit_boot_id = sw.boot_id,
		transfer = transfer,
	}, nil)
end

function Backend:commit_op(job, ctx)
	local component = component_of(self, job)
	local payload = {
		job_id = job.job_id,
		expected_image_id = expected_image_id(job, ctx),
		metadata = metadata_of(job),
	}
	return call_component_op(self, component, 'commit-update', payload):wrap(function (reply, err)
		if reply == nil then
			return nil, phase_error('component_commit_update_failed', err)
		end
		local accepted, rerr = validate_commit_reply(reply)
		if accepted == nil then return nil, rerr end
		return { accepted = true, reply = reply, component_reply = accepted }
	end)
end

function Backend:evaluate_reconcile(job, snapshot, ctx)
	local component = component_of(self, job)
	local state = component_snapshot(snapshot, component) or latest_component_state(self, component)
	local sw = state and state.software or nil
	local upd = updater_state(state) or {}
	local pre = (job.commit_attempt and job.commit_attempt.pre_commit)
		or (ctx and ctx.pre_commit)
	local expected = expected_image_id(job, ctx) or (pre and pre.expected_image_id)
	local pre_boot = pre and pre.pre_commit_boot_id

	if type(upd) == 'table' and upd.state == 'failed' then
		return { done = true, ok = false, reason = upd.last_error or upd.state, state = copy(state) }
	end
	if type(upd) == 'table' and upd.state == 'rollback_detected' then
		return { done = true, ok = false, reason = upd.state, state = copy(state) }
	end

	if component == 'mcu' then
		local missing = missing_mcu_critical_facts(state)
		if #missing > 0 then
			return {
				done = false,
				reason = 'waiting_for_mcu_critical_state',
				missing_facts = missing,
				required_facts = copy(MCU_CRITICAL_FACTS),
				state = copy(state),
			}
		end
	end

	if type(sw) == 'table' and expected and sw.image_id == expected and pre_boot and sw.boot_id ~= pre_boot then
		return { done = true, ok = true, state = copy(state) }
	end

	if type(sw) == 'table'
		and expected and pre_boot and sw.boot_id ~= nil
		and sw.boot_id ~= pre_boot and sw.image_id ~= expected
	then
		return { done = true, ok = false, reason = 'wrong_image_after_reboot', state = copy(state) }
	end

	return { done = false, reason = 'waiting_for_component_state', state = copy(state) }
end

function Backend:commit_capabilities()
	return { policy = self._commit_policy or 'no_duplicate' }
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_conn = opts.conn,
		_artifact_store = opts.artifact_store,
		_observer = opts.observer,
		_component = opts.component or 'mcu',
		_chunk_size = opts.chunk_size,
		_commit_policy = opts.commit_policy,
		_call_opts = opts.call_opts,
	}, Backend)
end

M.Backend = Backend
return M
