-- services/update/backends/component.lua
--
-- Canonical component update backend.  It knows Device's curated component
-- state/capability surface only; it has no Fabric, UART or raw-member knowledge.

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
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

local function required_string(v, field)
	if type(v) ~= 'string' or v == '' then
		return nil, field .. '_required'
	end
	return v, nil
end

local function job_expected_image_id(job)
	return required_string(type(job) == 'table' and job.expected_image_id or nil, 'expected_image_id')
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

local NO_BUS_TIMEOUT = { timeout = false }

local function call_component_op(self, component, method, payload, opts)
	if type(self._conn) ~= 'table' or type(self._conn.call_op) ~= 'function' then
		return op.always(nil, 'component_backend_connection_required')
	end
	-- Component update calls may legitimately take as long as the update phase
	-- owns them for.  Do not use lua-bus' default one-second call timeout here;
	-- callers that own a budget must compose this Op with a sleep/deadline Op.
	-- If that outer choice loses, lua-bus observes the abort and abandons the
	-- request through the Request owner path.
	return self._conn:call_op(topics.component_rpc(component, method), payload, opts or self._call_opts or NO_BUS_TIMEOUT):wrap(function (reply, err)
		if reply == false then return nil, err or 'component_call_failed' end
		return reply, err
	end)
end

local function retry_budget(self, ctx, method)
	local cfg = type(self._rpc_retry) == 'table' and self._rpc_retry or {}
	local attempts = tonumber(cfg.attempts) or tonumber(cfg.max_attempts) or 3
	if method == 'stage-update' then
		attempts = tonumber(cfg.stage_attempts) or attempts
	elseif method == 'commit-update' then
		attempts = tonumber(cfg.commit_attempts) or attempts
	elseif method == 'prepare-update' then
		attempts = tonumber(cfg.prepare_attempts) or attempts
	end
	if attempts < 1 then attempts = 1 end
	return math.floor(attempts)
end

local function retry_delay_s(self, attempt)
	local cfg = type(self._rpc_retry) == 'table' and self._rpc_retry or {}
	local base = tonumber(cfg.delay_s) or 0.20
	local max = tonumber(cfg.max_delay_s) or 1.00
	local n = base * (2 ^ math.max(0, attempt - 1))
	if n > max then n = max end
	return n
end

local function deadline_remaining(ctx)
	local deadline = ctx and ctx.deadline
	if type(deadline) ~= 'number' then return nil end
	local rem = deadline - fibers.now()
	if rem <= 0 then return 0 end
	return rem
end

local function call_component_retry_op(self, component, method, payload, ctx, opts)
	return fibers.run_scope_op(function ()
		local attempts = retry_budget(self, ctx, method)
		local last_err
		for attempt = 1, attempts do
			local rem = deadline_remaining(ctx)
			if rem ~= nil and rem <= 0 then
				return nil, (method .. '_timeout')
			end

			local reply, err
			if rem ~= nil then
				local which, a, b = fibers.perform(fibers.named_choice {
					call = call_component_op(self, component, method, payload, opts),
					timeout = sleep.sleep_op(rem),
				})
				if which == 'timeout' then
					return nil, (method .. '_timeout')
				end
				reply, err = a, b
			else
				reply, err = fibers.perform(call_component_op(self, component, method, payload, opts))
			end

			if reply ~= nil then
				return reply, nil, attempt
			end
			last_err = err or (method .. '_failed')
			if attempt >= attempts then break end

			local delay = retry_delay_s(self, attempt)
			local rem2 = deadline_remaining(ctx)
			if rem2 ~= nil then
				if rem2 <= 0 then return nil, (method .. '_timeout') end
				if delay > rem2 then delay = rem2 end
			end
			if delay > 0 then fibers.perform(sleep.sleep_op(delay)) end
		end
		return nil, last_err or (method .. '_failed')
	end):wrap(function (st, report, value, err)
		if st == 'ok' then
			return value, err
		end
		return nil, value or err or report or st or (method .. '_failed')
	end)
end

local function call_component_once_op(self, component, method, payload, ctx, opts)
	return fibers.run_scope_op(function ()
		local rem = deadline_remaining(ctx)
		if rem ~= nil and rem <= 0 then return nil, method .. '_timeout' end
		if rem ~= nil then
			local which, a, b = fibers.perform(fibers.named_choice {
				call = call_component_op(self, component, method, payload, opts),
				timeout = sleep.sleep_op(rem),
			})
			if which == 'timeout' then return nil, method .. '_timeout' end
			return a, b
		end
		return fibers.perform(call_component_op(self, component, method, payload, opts))
	end):wrap(function (st, report, value, err)
		if st == 'ok' then return value, err end
		return nil, value or err or report or st or (method .. '_failed')
	end)
end


local function commit_response_may_be_missing(err)
	-- Only timeouts/closed response paths are ambiguous enough to treat as
	-- "commit may have reached the MCU; response may have been lost".
	-- Definite admission/routing failures such as link_not_ready, no_route or
	-- no_session must remain ordinary failures and must not advance the job to
	-- awaiting_return.
	if err == nil or err == '' then return true end
	if err == 'timeout' or err == 'commit-update_timeout' then return true end
	if err == 'bus_call_closed' or err == 'local_call_closed' or err == 'reply_closed' then return true end
	return false
end

local function commit_reply_ok(reply)
	if type(reply) ~= 'table' then return nil, 'invalid_commit_reply' end
	if reply.ok == false then return nil, reply.err or reply.error or reply.reason or 'component_commit_update_failed' end
	if reply.accepted == false then return nil, reply.err or reply.error or reply.reason or 'commit_not_accepted' end
	if reply.accepted == true or reply.reboot_required ~= nil then return true, nil end
	return nil, 'invalid_commit_reply'
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
		local image_id, iid_err = job_expected_image_id(job)
		if not image_id then return nil, iid_err end

		local prepare_payload = {
			job_id = job.job_id,
			target = component,
			expected_image_id = image_id,
			metadata = metadata_of(job),
		}
		local prepared, perr = fibers.perform(call_component_retry_op(self, component, 'prepare-update', prepare_payload, ctx))
		if prepared == nil then return nil, perr or 'component_prepare_update_failed' end

		local stage_attempts = retry_budget(self, ctx, 'stage-update')
		local reply, err
		for attempt = 1, stage_attempts do
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
			reply, err = fibers.perform(call_component_once_op(self, component, 'stage-update', payload, ctx))
			if reply ~= nil then break end
			if attempt >= stage_attempts then break end
			local delay = retry_delay_s(self, attempt)
			local rem = deadline_remaining(ctx)
			if rem ~= nil then
				if rem <= 0 then return nil, 'stage-update_timeout' end
				if delay > rem then delay = rem end
			end
			if delay > 0 then fibers.perform(sleep.sleep_op(delay)) end
		end
		if reply == nil then return nil, err or 'component_stage_update_failed' end
		local ok_reply, rerr = validate_stage_reply(reply)
		if ok_reply ~= true then return nil, rerr end
		local payload = {
			digest_alg = desc.digest_alg or 'xxhash32',
			digest = desc.digest or desc.checksum,
			size = desc.size,
		}
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
	local image_id, iid_err = job_expected_image_id(job)
	if not image_id then return op.always(nil, iid_err) end
	local transfer = transfer_from(job, ctx)
	return op.always({
		component = component,
		expected_image_id = image_id,
		pre_commit_image_id = sw.image_id,
		pre_commit_boot_id = sw.boot_id,
		transfer = transfer,
	}, nil)
end

function Backend:commit_op(job, ctx)
	local component = component_of(self, job)
	local job_id, jid_err = required_string(type(job) == 'table' and job.job_id or nil, 'job_id')
	if not job_id then return op.always(nil, jid_err) end
	local image_id, iid_err = job_expected_image_id(job)
	if not image_id then return op.always(nil, iid_err) end
	local payload = {
		job_id = job_id,
		expected_image_id = image_id,
		commit_token = ctx and ctx.commit_token or nil,
	}
	return call_component_retry_op(self, component, 'commit-update', payload, ctx):wrap(function (reply, err)
		if reply == nil then
			if not commit_response_may_be_missing(err) then
				return nil, err or 'component_commit_update_failed'
			end
			-- Once commit has plausibly been submitted and the response path is
			-- uncertain, the safe update-state transition is
			-- awaiting_return/reconcile.  A missing reply may mean the MCU accepted
			-- and is rebooting.  Reconcile will decide whether the image actually
			-- took.
			return { accepted = true, uncertain = true, reason = err or 'commit_response_missing' }
		end
		local ok_reply, rerr = commit_reply_ok(reply)
		if ok_reply ~= true then return nil, rerr end
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
	local expected, iid_err = job_expected_image_id(job)
	if not expected then
		return { done = true, ok = false, reason = iid_err, state = copy(state) }
	end
	local pre_boot = pre and pre.pre_commit_boot_id

	if type(upd) == 'table' and (upd.state == 'failed' or upd.state == 'rollback_detected') then
		return { done = true, ok = false, reason = upd.state, state = copy(state) }
	end

	if type(sw) == 'table' and expected and sw.image_id == expected and pre_boot and sw.boot_id ~= pre_boot then
		return { done = true, ok = true, state = copy(state) }
	end

	local commit_result = type(job) == 'table' and type(job.commit_result) == 'table' and job.commit_result or nil
	if type(sw) == 'table' and expected and sw.image_id == expected and not pre_boot
		and commit_result and commit_result.tag == 'artifact_missing_reconcile' then
		return { done = true, ok = true, state = copy(state), reason = 'artifact_missing_reconciled_by_image' }
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
		_rpc_retry = opts.rpc_retry,
	}, Backend)
end

M.Backend = Backend
return M
