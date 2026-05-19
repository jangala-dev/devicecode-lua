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
	return self._conn:call_op(topics.component_rpc(component, method), payload, opts or self._call_opts):wrap(function (reply, err)
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

local function describe_artifact(artifact)
	if type(artifact) == 'table' and type(artifact.describe) == 'function' then
		local ok, rec = pcall(function () return artifact:describe() end)
		if ok and type(rec) == 'table' then return rec end
	end
	return type(artifact) == 'table' and artifact or nil
end

function Backend:stage_op(job, ctx)
	return unwrap_scope_value(fibers.run_scope_op(function ()
		local component = component_of(self, job)
		local ref = artifact_ref(job)
		if not ref then return nil, 'artifact_ref_required' end
		if not self._artifact_store or type(self._artifact_store.open_op) ~= 'function' then
			return nil, 'artifact_store_unavailable'
		end
		if type(self._artifact_store.open_source_op) ~= 'function' then
			return nil, 'artifact_source_unavailable'
		end

		local artifact, aerr = fibers.perform(self._artifact_store:open_op(ref))
		if artifact == nil then return nil, aerr or 'artifact_open_failed' end
		local desc = describe_artifact(artifact) or {}
		local meta = type(desc.meta) == 'table' and desc.meta or desc.metadata or {}
		local image_id = expected_image_id(job, { preflight = desc })
			or meta.expected_image_id or meta.image_id

		local prepare_payload = {
			job_id = job.job_id,
			expected_image_id = image_id,
			metadata = metadata_of(job),
		}
		local prepared, perr = fibers.perform(call_component_op(self, component, 'prepare-update', prepare_payload))
		if prepared == nil then return nil, perr or 'component_prepare_update_failed' end

		local source, serr = fibers.perform(self._artifact_store:open_source_op(ref))
		if source == nil then return nil, serr or 'artifact_source_open_failed' end
		local payload = {
			job_id = job.job_id,
			expected_image_id = image_id,
			source = source,
			size = desc.size,
			digest_alg = desc.digest_alg or 'xxhash32',
			digest = desc.digest or desc.checksum,
			chunk_size = self._chunk_size or 2048,
			format = meta.format or desc.format or 'dcmcu-v1',
			metadata = metadata_of(job),
		}
		local reply, err = fibers.perform(call_component_op(self, component, 'stage-update', payload))
		if reply == nil then return nil, err or 'component_stage_update_failed' end
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

local function component_snapshot(snapshot, component)
	if type(snapshot) ~= 'table' then return nil end
	local by_id = snapshot.by_id or snapshot.components
	local rec = type(by_id) == 'table' and by_id[component] or nil
	if type(rec) == 'table' and type(rec.state) == 'table' then return rec.state end
	if type(rec) == 'table' then return rec end
	if snapshot.component == component then return snapshot.state or snapshot end
	return nil
end

local function latest_component_state(self, component)
	local obs = self._observer
	if obs and type(obs.snapshot) == 'function' then
		return component_snapshot(obs:snapshot(), component)
	end
	return nil
end

local function updater_state(state)
	if type(state) ~= 'table' then return nil end
	return state.update or state.updater
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
		if reply == nil then return nil, err or 'component_commit_update_failed' end
		return { accepted = true, reply = reply }
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

	if type(upd) == 'table' and (upd.state == 'failed' or upd.state == 'rollback_detected') then
		return { done = true, ok = false, reason = upd.state, state = copy(state) }
	end

	if type(sw) == 'table' and expected and sw.image_id == expected and pre_boot and sw.boot_id ~= pre_boot then
		return { done = true, ok = true, state = copy(state) }
	end

	if type(sw) == 'table' and expected and pre_boot and sw.boot_id ~= nil and sw.boot_id ~= pre_boot and sw.image_id ~= expected then
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
		_chunk_size = opts.chunk_size or 2048,
		_commit_policy = opts.commit_policy,
		_call_opts = opts.call_opts,
	}, Backend)
end

M.Backend = Backend
return M
