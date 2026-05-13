-- services/device/action_worker.lua
--
-- Scoped component action execution. Action workers own caller-visible request
-- resolution and any temporary resources they create.

local fibers        = require 'fibers'
local cond          = require 'fibers.cond'
local op            = require 'fibers.op'
local sleep         = require 'fibers.sleep'
local scope_mod     = require 'fibers.scope'
local request_owner = require 'devicecode.support.request_owner'
local resource      = require 'devicecode.support.resource'
local fabric_stage  = require 'services.device.fabric_stage'

local M = {}

local function request_payload(req)
	if type(req) ~= 'table' then return nil end
	return req.payload
end

local function default_call_op(conn, topic, payload, opts)
	if type(conn) == 'table' and type(conn.call_op) == 'function' then
		return conn:call_op(topic, payload, opts)
	end

	return nil, 'connection does not support call_op'
end

local function normalise_reply(reply)
	if type(reply) == 'table' and reply.ok == false then
		return nil, reply.reason or reply.err or 'action failed'
	end
	if type(reply) == 'table' and reply.ok == true and reply.reason ~= nil then
		return reply.reason, nil
	end
	return reply, nil
end

local function public_result(status, fields)
	fields = fields or {}
	fields.public_status = status
	fields.ok = (status == 'succeeded')
	if fields.err ~= nil and fields.error == nil then
		fields.error = fields.err
	end
	if fields.error ~= nil and fields.err == nil then
		fields.err = fields.error
	end
	return fields
end


local INTERNAL_PUBLIC_KEYS = {
	source_handoff = true,
	receiver_install = true,
}

local function sanitise_public_payload(value, seen)
	if type(value) ~= 'table' then return value end
	seen = seen or {}
	if seen[value] then return nil end
	seen[value] = true

	local out = {}
	for k, v in pairs(value) do
		if not INTERNAL_PUBLIC_KEYS[k] and type(v) ~= 'function' then
			out[k] = sanitise_public_payload(v, seen)
		end
	end
	seen[value] = nil
	return out
end

local function public_reply_payload(result)
	if type(result) == 'table' and result.reply_payload ~= nil then
		return sanitise_public_payload(result.reply_payload)
	end
	return sanitise_public_payload(result)
end

local function finalise_owner(owner, status, primary)
	if owner:done() then return end
	if status == 'cancelled' then
		owner:finalise_unresolved(primary or 'cancelled')
	elseif status == 'failed' then
		owner:finalise_unresolved(primary or 'failed')
	else
		owner:finalise_unresolved(primary or 'terminated')
	end
end

local function run_rpc_op(ctx, owner)
	local action = ctx.action_spec
	local payload = request_payload(ctx.request)
	local call_ev, cerr = default_call_op(ctx.conn, action.call_topic, payload, {
		timeout = action.timeout or ctx.timeout,
		deadline = ctx.deadline,
	})

	if not call_ev then
		local reason = cerr or 'rpc_unavailable'
		owner:fail_once(reason)
		return op.always(public_result('unavailable', { err = reason }))
	end

	return call_ev:wrap(function (reply, err)
		if reply == nil then
			local reason = err or 'rpc_failed'
			owner:fail_once(reason)
			return public_result('remote_failed', { err = reason })
		end

		local value, rerr = normalise_reply(reply)
		if value == nil and rerr ~= nil then
			owner:fail_once(rerr)
			return public_result('remote_failed', { err = rerr })
		end

		owner:reply_once(value)
		return public_result('succeeded', { value = value, reply_payload = value })
	end)
end

local function is_op(v)
	return type(v) == 'table' and getmetatable(v) == op.Op
end

local function open_source_op(ctx)
	local payload = request_payload(ctx.request) or {}
	local opener = ctx.open_source_op

	if type(opener) == 'function' then
		local ev, err = opener(payload, ctx)
		if ev == nil then return op.always(nil, err or 'source_required') end
		if not is_op(ev) then return op.always(ev, nil) end
		return ev
	end

	opener = ctx.open_source
	if type(opener) == 'function' then
		local source, err = opener(payload, ctx)
		if is_op(source) then return source end
		return op.always(source, err)
	end

	if payload.source ~= nil then return op.always(payload.source, nil) end
	if payload.artifact ~= nil then return op.always(payload.artifact, nil) end
	return op.always(nil, 'source_required')
end


local function source_terminator(ctx)
	local terminate = ctx.terminate_source
	if terminate ~= nil and type(terminate) ~= 'function' then
		error('terminate_source must be a function', 0)
	end
	return terminate
end

local function run_fabric_stage_op(_, ctx, owner)
	-- Fabric staging is a meaningful sub-lifetime of the action: it may open a
	-- source, own termination responsibility, wait on a Fabric client, and hand ownership away.  Keep
	-- that lifetime visible as a child scope rather than hiding it in a guard or
	-- in the parent action finaliser.
	return fibers.run_scope_op(function (stage_scope)
		local source, err = fibers.perform(open_source_op(ctx))
		if not source then
			owner:fail_once(err or 'source_required')
			return public_result('rejected', { err = err or 'source_required' })
		end

		local owned = resource.owned(source, {
			terminate = source_terminator(ctx),
			label = 'device fabric-stage source termination',
		})
		stage_scope:finally(function (_, status, primary)
			owned:terminate_checked(
				primary or status or 'fabric_stage_terminated',
				'device fabric-stage source termination failed'
			)
		end)

		local result, ferr, handoff = fibers.perform(fabric_stage.stage_source_op(stage_scope, {
			client = ctx.fabric_client,
			source = owned:value(),
			component = ctx.component_id,
			action = ctx.action,
			link_id = ctx.action_spec.link_id,
			receiver = ctx.action_spec.receiver,
			artifact_store = ctx.action_spec.artifact_store,
			request_payload = request_payload(ctx.request),
			timeout = ctx.action_spec.timeout or ctx.timeout,
			deadline = ctx.deadline,
		}))

		if not result then
			local reason = ferr or 'fabric_stage_failed'
			owner:fail_once(reason)
			return public_result('remote_failed', { err = reason })
		end

		local consumed = handoff and handoff.consumed == true
		if consumed then
			local _, herr = owned:handoff(handoff.receiver_install)
			if herr ~= nil then
				owner:fail_once(herr)
				return public_result('failed', { err = herr })
			end
		end

		local public_payload = public_reply_payload(result)
		owner:reply_once(public_payload)
		return public_result('succeeded', {
			value = public_payload,
			reply_payload = public_payload,
		})
	end):wrap(function (st, _rep, result_or_primary)
		if st == 'ok' then
			return result_or_primary
		end

		local reason = result_or_primary or st or 'fabric_stage_failed'
		owner:fail_once(reason)
		return public_result(st == 'cancelled' and 'cancelled' or 'failed', { err = reason })
	end)
end

local function action_op(scope, ctx, owner)
	local action_spec = ctx.action_spec
	if action_spec.kind == 'fabric_stage' then
		return run_fabric_stage_op(scope, ctx, owner)
	end
	return run_rpc_op(ctx, owner)
end

local function perform_with_timeout(scope, ctx, ev)
	local timeout = ctx.timeout
	if ctx.action_spec and type(ctx.action_spec.timeout) == 'number' then
		timeout = ctx.action_spec.timeout
	end

	if timeout ~= nil then
		if type(timeout) ~= 'number' then
			error('action timeout must be a number', 0)
		end
		if timeout <= 0 then
			scope:cancel('timeout')
			return public_result('timed_out', { err = 'timeout' })
		end

		-- Timeout is an ownership decision, not just a competing result.  A small
		-- timer fibre cancels the action scope; cancellation then cascades by
		-- parentage into any HAL/Fabric child scopes.  This avoids aborting a child
		-- run_scope_op with a generic losing-choice reason before the action scope
		-- has been cancelled with the public timeout reason.
		local done = cond.new()
		local ok_timer, timer_err = fibers.spawn(function ()
			local timed_out = fibers.perform(fibers.boolean_choice(
				sleep.sleep_op(timeout),
				done:wait_op()
			))
			if timed_out then
				scope:cancel('timeout')
			end
		end)
		if ok_timer ~= true then
			-- The action body may first run after its owning action scope has
			-- already been cancelled by generation replacement or service shutdown.
			-- In that case timeout-helper admission being closed is not a worker
			-- failure; preserve the scope cancellation reason so the request-owner
			-- finaliser reports the real ownership decision.
			local st, reason = scope:status()
			if st == 'cancelled' then
				error(scope_mod.cancelled(reason or timer_err or 'cancelled'), 0)
			end
			error(timer_err or 'action timeout timer start failed', 0)
		end

		scope:finally(function ()
			done:signal()
		end)

		local result = fibers.perform(ev)
		done:signal()
		return result
	end

	return fibers.perform(ev)
end

function M.run(scope, ctx)
	ctx = ctx or {}
	if fibers.current_scope and fibers.current_scope() ~= scope then
		error('device action worker must run in its owning scope', 0)
	end
	local req = assert(ctx.request, 'device action worker requires request')
	local action_spec = assert(ctx.action_spec, 'device action worker requires action_spec')
	local owner = ctx.request_owner or request_owner.new(req, ctx.request_owner_opts)

	-- When action work is launched through action_manager, the request owner is
	-- installed in scoped_work setup before the worker fibre is admitted.  That
	-- closes the ownership gap where a generation can be cancelled after
	-- admission but before this worker body has run.  Direct users of
	-- action_worker.run still get the same finaliser here.
	if ctx.request_owner == nil then
		scope:finally(function (_, status, primary)
			finalise_owner(owner, status, primary)
		end)
	end

	local result = perform_with_timeout(scope, ctx, action_op(scope, ctx, owner))
	result = result or public_result('failed', { err = 'action returned no result' })
	if result.public_status == 'timed_out' and not owner:done() then
		owner:fail_once(result.err or result.error or 'timeout')
	end

	return {
		component = ctx.component_id,
		action = ctx.action,
		request_id = ctx.request_id,
		ok = result.ok == true,
		public_status = result.public_status or (result.ok == true and 'succeeded' or 'remote_failed'),
		value = result.value or result.reply_payload,
		reply_payload = result.reply_payload,
		err = result.err or result.error,
		error = result.error or result.err,
	}
end

M.finalise_owner = finalise_owner
M.sanitise_public_payload = sanitise_public_payload

return M
