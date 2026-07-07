-- services/ui/http/listener.lua
--
-- UI HTTP listener consumer.
--
-- UI does not own the HTTP backend.  It obtains an HttpListener local handle
-- from the HTTP capability service, accepts HttpContext handles, and transfers
-- each accepted context into a request scope before any request work runs.

local fibers      = require 'fibers'
local resource    = require 'devicecode.support.resource'
local scoped_work = require 'devicecode.support.scoped_work'
local http_sdk    = require 'services.http'.sdk
local safe        = require 'coxpcall'

local M = {}

local function emit(opts, ev)
	local port = opts and opts.events_port
	if not (port and type(port.emit_required) == 'function') then
		error('ui.http.listener requires events_port', 3)
	end
	local ok, err = port:emit_required(ev, 'ui_http_listener_report_failed')
	if ok ~= true then error(err or 'ui_http_listener_report_failed', 3) end
	return true, nil
end

local function terminate(obj, reason)
	if obj == nil then return true, nil end
	if type(obj) ~= 'table' then return nil, 'resource has no terminate method' end
	if type(obj.terminate) == 'function' then return obj:terminate(reason) end
	return nil, 'resource has no terminate method'
end

local function terminate_checked(obj, reason, label)
	local ok, err = terminate(obj, reason)
	if ok ~= true then error((label or 'resource termination failed') .. ': ' .. tostring(err), 2) end
	return true
end

local function max_active_from(opts)
	local n = opts.max_active_requests
	if n == nil then return nil end
	if type(n) ~= 'number' or n < 0 or n % 1 ~= 0 then
		error('http.listener.run: max_active_requests must be a non-negative integer', 3)
	end
	return n
end

local function default_run_request(scope, ctx, opts)
	local request_mod = require 'services.ui.http.request'
	return request_mod.run(scope, ctx, opts)
end

local function request_id_of(ctx, next_id)
	if type(ctx) == 'table' then
		if type(ctx.id) == 'function' then
			local ok, id = safe.pcall(function () return ctx:id() end)
			if ok and id ~= nil then return id end
		end
		if ctx.id ~= nil then return ctx.id end
	end
	return next_id
end

local function reject_overloaded(ctx, opts)
	local reason = opts.overload_reason or 'http_request_backpressure'
	if type(opts.reject_overloaded_request_now) == 'function' then
		return opts.reject_overloaded_request_now(ctx, reason, opts)
	end
	return terminate(ctx, reason)
end

local function install_request_owner(request_scope, accepted_owner)
	local request_owner
	local ctx, err = accepted_owner:handoff(function (value)
		request_owner = resource.owned(value, {
			label = 'HTTP request context termination',
			terminate = function (v, reason)
				return terminate(v, reason)
			end,
		})
		request_scope:finally(function (_, status, primary)
			request_owner:terminate_checked(primary or status or 'terminated', 'HTTP request context termination')
		end)
		return true, nil
	end)
	if ctx == nil then return nil, err end

	return {
		ctx = ctx,
		owner = request_owner,
		cancel_owned_now = function (reason)
			if request_owner and request_owner:is_owned() then
				return request_owner:terminate(reason or 'request_cancelled')
			end
			return terminate(ctx, reason or 'request_cancelled')
		end,
	}, nil
end

local function obtain_listener_op(opts)
	if opts.listener then
		return fibers.always(opts.listener, nil)
	end

	if type(opts.obtain_listener_op) == 'function' then
		return opts.obtain_listener_op(opts)
	end

	local conn = opts.conn
	if conn == nil then return fibers.always(nil, 'http.listener.run: conn required') end

	local cap_id = opts.cap_id or 'main'
	local listen_args = opts.listen or {}
	if type(listen_args) ~= 'table' then return fibers.always(nil, 'http.listener.run: listen opts must be a table') end
	local ref = http_sdk.new_ref(conn, cap_id)
	return ref:listen_op(listen_args, opts.call_opts):wrap(function (reply, err)
		if reply == nil then return nil, err or 'http_listen_failed' end
		return reply.listener, nil
	end)
end

function M.run(scope, opts)
	opts = opts or {}

	local run_request = opts.run_request or default_run_request
	if type(run_request) ~= 'function' then
		error('http.listener.run: run_request must be a function', 2)
	end

	local listener = opts.listener

	-- A supplied listener is already being handed into this scope.  Install the
	-- terminating finaliser before any scope-aware perform so an immediate
	-- cancellation during start-up cannot leak the handle.  For SDK-created
	-- listeners the same finaliser is installed first and becomes active as soon
	-- as listener is assigned.
	scope:finally(function (_, status, primary)
		if listener ~= nil then
			terminate_checked(listener, primary or status or 'http_listener_closed', 'HTTP listener termination')
		end
	end)

	if listener == nil then
		local listen_err
		listener, listen_err = fibers.perform(obtain_listener_op(opts))
		if listener == nil then error(listen_err or 'http.listener.run: listener unavailable', 0) end
	end

	if type(listener.accept_op) ~= 'function' then
		error('http.listener.run: listener must expose accept_op', 2)
	end

	local active = 0
	local next_id = 0
	local max_active = max_active_from(opts)

	while true do
		local ctx, err = fibers.perform(listener:accept_op())
		if ctx == nil then error(err or 'http accept failed', 0) end

		next_id = next_id + 1
		local request_id = request_id_of(ctx, next_id)

		if max_active ~= nil and active >= max_active then
			local ok, rerr = reject_overloaded(ctx, opts)
			emit(opts, {
				kind = 'http_request_rejected',
				request_id = request_id,
				reason = opts.overload_reason or 'http_request_backpressure',
				active_requests = active,
				max_active_requests = max_active,
				cleanup_ok = ok == true,
				cleanup_err = rerr,
			})
			if ok ~= true then error(rerr or 'http overloaded request cleanup failed', 0) end
		else
			local accepted_owner = resource.owned(ctx, {
				label = 'accepted HTTP context cleanup',
				terminate = function (value, reason)
					return terminate(value, reason)
				end,
			})
			active = active + 1
			emit(opts, {
				kind = 'http_request_started',
				request_id = request_id,
				active_requests = active,
			})

			local handle, start_err = scoped_work.start({
				lifetime_scope = scope,
				reaper_scope = scope,
				report_scope = scope,
				identity = {
					kind = 'http_request_done',
					request_id = request_id,
				},
				setup = function (request_scope)
					return install_request_owner(request_scope, accepted_owner)
				end,
				run = function (request_scope, setup)
					return run_request(request_scope, setup.ctx, opts)
				end,
				report = function (ev)
					active = math.max(0, active - 1)
					ev.active_requests = active
					return emit(opts, ev)
				end,
			})

			if not handle then
				active = math.max(0, active - 1)
				if accepted_owner:is_owned() then
					accepted_owner:terminate_checked(start_err or 'http_request_start_failed', 'HTTP request start-failure cleanup')
				end
				emit(opts, {
					kind = 'http_request_done',
					request_id = request_id,
					status = 'failed',
					primary = start_err,
					active_requests = active,
				})
			end
		end
	end
end

M._test = {
	emit = emit,
	max_active_from = max_active_from,
	reject_overloaded = reject_overloaded,
	install_request_owner = install_request_owner,
	obtain_listener_op = obtain_listener_op,
	terminate = terminate,
}

return M
