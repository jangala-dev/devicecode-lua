-- services/http/listener_owner.lua
-- Named listener runtime owner.
--
-- A listen RPC performs setup only until the listener is bound.  The listener
-- runtime then lives in a child owner scope under the HTTP service.  Accepted
-- contexts transfer to caller/request scopes via accept_op().  Runtime
-- completion is reported as an identity-bearing scoped-work completion.

local fibers = require 'fibers'
local cond   = require 'fibers.cond'

local listener_mod = require 'services.http.listener'
local scoped_work  = require 'devicecode.support.scoped_work'

local M = {}

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function make_listener(opts)
	local made, err = listener_mod.listen(opts)
	if not made then return nil, err or 'listen_create_failed' end
	return made, nil
end

function M.start(spec)
	if type(spec) ~= 'table' then return nil, 'invalid_args' end
	local lifetime_scope = spec.lifetime_scope
	if not lifetime_scope or type(lifetime_scope.child) ~= 'function' then return nil, 'lifetime_scope_required' end

	local opts = copy(spec.listen_opts or {})
	local events_port = spec.events_port
	local identity = {
		kind = 'listener_done',
		handle_id = spec.handle_id,
		generation = spec.generation or 1,
	}
	if events_port ~= nil and (type(events_port) ~= 'table' or type(events_port.emit_required) ~= 'function') then
		return nil, 'events_port_required'
	end
	local function emit(ev, label)
		if not events_port then return true, nil end
		return events_port:emit_required(ev, label or 'http_listener_owner_event_report_failed')
	end

	local ready = cond.new()
	local ready_done = false
	local ready_listener, ready_err

	local function signal_ready(listener, err)
		if ready_done then return end
		ready_done = true
		ready_listener = listener
		ready_err = err
		ready:signal()
	end

	local handle, err, setup = scoped_work.start({
		lifetime_scope = lifetime_scope,
		reaper_scope = lifetime_scope,
		report_scope = lifetime_scope,
		identity = identity,

		setup = function ()
			local listener, lerr = make_listener(opts)
			if not listener then return nil, lerr or 'listen_create_failed' end
			return {
				listener = listener,
				cancel_owned_now = function (reason)
					listener:terminate(reason or 'listener_start_cancelled')
					return true
				end,
			}
		end,

		run = function (scope, run_setup)
			local listener = assert(run_setup.listener)
			scope:finally(function (_, status, primary)
				listener:terminate(primary or status or 'listener_scope_finalised')
			end)

			local ok, lerr = fibers.perform(listener:listen_op())
			if not ok then
				listener:terminate(lerr or 'listener_listen_failed')
				signal_ready(nil, lerr or 'listener_listen_failed')
				error(lerr or 'listener_listen_failed', 0)
			end

			local spawned, spawn_err = scope:spawn(function ()
				while true do
					local ctx, cerr = fibers.perform(listener:context_admission_op())
					if ctx == nil then
						if cerr == nil or tostring(cerr):match('closed') or tostring(cerr):match('listener') then
							return true
						end
						error(cerr, 0)
					end
				end
			end)
			if spawned ~= true then
				listener:terminate(spawn_err or 'listener_context_manager_spawn_failed')
				signal_ready(nil, spawn_err or 'listener_context_manager_spawn_failed')
				error(spawn_err or 'listener_context_manager_spawn_failed', 0)
			end

			emit({
				kind = 'listener_owner_started',
				handle_id = identity.handle_id,
				generation = identity.generation,
			})
			signal_ready(listener, nil)

			local rok, rerr = listener:run()
			if not rok then error(rerr or 'listener_runtime_failed', 0) end
			return {
				handle_id = identity.handle_id,
				reason = listener:why() or 'listener_runtime_ended',
			}
		end,

		report = function (ev)
			return emit(ev, 'http_listener_owner_done_report_failed')
		end,
	})

	if not handle then
		return nil, err or 'listener_start_failed'
	end

	local listener, wait_err = fibers.perform(ready:wait_op():wrap(function ()
		return ready_listener, ready_err
	end):on_abort(function ()
		handle:cancel('listener_start_cancelled')
	end))
	if not listener then
		handle:cancel(wait_err or 'listener_start_failed')
		return nil, wait_err or 'listener_start_failed'
	end

	return {
		listener = listener,
		scope = setup and setup.scope,
		work = handle,
		cancel = function (_, reason)
			handle:cancel(reason or 'listener_cancelled')
			listener:terminate(reason or 'listener_cancelled')
			return true
		end,
		outcome_op = function () return handle:outcome_op() end,
		outcome = function () return handle:outcome() end,
	}, nil
end

return M
