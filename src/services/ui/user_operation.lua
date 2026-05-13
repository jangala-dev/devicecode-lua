-- services/ui/user_operation.lua
--
-- Authenticated scoped upstream calls. This is for request/client operation
-- scopes, not service coordinators.
--
-- Timeout is modelled as a race against the whole operation scope. If the
-- timeout wins, run_scope_op's abort path cancels and joins the operation
-- scope, running the owned connection finaliser before the boundary returns
-- cancelled, "timeout".

local fibers      = require 'fibers'
local sleep       = require 'fibers.sleep'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local resource    = require 'devicecode.support.resource'

local M = {}

local function connect_for(spec)
	if type(spec.connect) == 'function' then
		return spec.connect(spec.principal, spec)
	end
	if spec.bus and type(spec.bus.connect) == 'function' then
		return spec.bus:connect({ principal = spec.principal })
	end
	if spec.conn ~= nil then
		return spec.conn
	end
	return nil, 'no user_operation connection source'
end

local function disconnect_if_owned(conn, spec)
	if spec.conn ~= nil and conn == spec.conn and not spec.disconnect_borrowed then
		return true, nil
	end
	return bus_cleanup.disconnect(conn)
end

local function normalise_result(result)
	if type(result) == 'table' then return result end
	return { value = result }
end

local function timeout_report()
	return { id = 0, extra_errors = {}, children = {}, timeout = true }
end

local function deadline_from_spec(spec)
	if type(spec.deadline) == 'number' then
		return spec.deadline
	end
	if type(spec.timeout) == 'number' then
		return fibers.now() + spec.timeout
	end
	return nil
end

local function operation_body_op(spec)
	return fibers.run_scope_op(function (scope)
		local conn, cerr = connect_for(spec)
		if not conn then error(cerr or 'user connection failed', 0) end

		local conn_owner = resource.owned(conn, {
			label = 'user operation connection cleanup',
			terminate = function (value)
				return disconnect_if_owned(value, spec)
			end,
		})

		scope:finally(function (_, status, primary)
			conn_owner:terminate_checked(
				primary or status or 'user_operation_closed',
				'user operation connection cleanup'
			)
		end)

		if type(spec.run_op) == 'function' then
			local result, err = fibers.perform(spec.run_op(scope, conn))
			if result == nil then error(err or 'user_operation_failed', 0) end
			return normalise_result(result)
		end

		return normalise_result(spec.run(scope, conn))
	end)
end

function M.run_op(spec)
	spec = spec or {}
	if type(spec.run_op) ~= 'function' and type(spec.run) ~= 'function' then
		error('user_operation.run_op: run_op or run function required', 2)
	end

	return fibers.guard(function ()
		local deadline = deadline_from_spec(spec)
		local work = operation_body_op(spec)
		if deadline == nil then
			return work
		end

		local dt = deadline - fibers.now()
		if dt <= 0 then
			return fibers.always('cancelled', timeout_report(), 'timeout')
		end

		return fibers.boolean_choice(work, sleep.sleep_op(dt)):wrap(function (work_won, st, rep, value_or_primary)
			if work_won then
				return st, rep, value_or_primary
			end
			return 'cancelled', timeout_report(), 'timeout'
		end)
	end)
end

function M.run(spec)
	local st, rep, a = fibers.perform(M.run_op(spec))
	if st == 'ok' then return a, nil, rep end
	return nil, a, rep
end

return M
