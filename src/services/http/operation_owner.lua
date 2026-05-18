-- services/http/operation_owner.lua
-- Request-owner and scoped_work glue for HTTP capability operations.

local request_owner = require 'devicecode.support.request_owner'
local scoped_work = require 'devicecode.support.scoped_work'
local service_events = require 'devicecode.support.service_events'

local M = {}

function M.next_request(service, verb, req)
	service._next_request_id = service._next_request_id + 1
	local request_id = 'req' .. tostring(service._next_request_id)
	local owner = request_owner.new(req)
	service._owned_requests[request_id] = owner
	return request_id, owner
end

function M.operation_identity(service, verb, request_id)
	service._next_operation_id = service._next_operation_id + 1
	return {
		kind = 'http_operation_done',
		operation = verb,
		operation_id = 'op' .. tostring(service._next_operation_id),
		request_id = request_id,
		generation = service._generation,
	}
end

function M.operation_setup(service, owner)
	return function (scope)
		scope:finally(function (_, status, primary)
			if status ~= 'ok' then
				owner:finalise_unresolved(primary or status or 'http_request_finalised')
			end
		end)
		return {
			owner = owner,
			reserved_handles = {},
			cancel_owned_now = function (reason)
				if not owner:done() then
					owner:finalise_unresolved(reason or 'scoped_work_start_failed')
				end
				return true
			end,
		}
	end
end

function M.start(service, verb, req, request_id, owner, run)
	local identity = M.operation_identity(service, verb, request_id)
	service._state.operations[identity.operation_id] = {
		operation_id = identity.operation_id,
		generation = identity.generation,
		operation = verb,
		request_id = request_id,
		state = 'admitted',
	}
	local reqrec = service._state.requests[request_id]
	if reqrec then reqrec.state = 'running'; reqrec.operation_id = identity.operation_id end
	service:_log_event { kind = 'operation_started', operation = verb, operation_id = identity.operation_id, request_id = request_id, generation = identity.generation }

	local setup_fn = function (scope)
		local setup = M.operation_setup(service, owner)(scope)
		local old_cancel = setup.cancel_owned_now
		setup.cancel_owned_now = function (reason)
			old_cancel(reason)
			for _, handle_id in ipairs(setup.reserved_handles or {}) do service:_terminate_handle(handle_id, reason or 'operation_start_failed') end
			return true
		end
		return setup
	end

	local events_port = service._event_port and service:_event_port({
		source = 'http_operation',
		source_id = identity.operation_id,
		operation_id = identity.operation_id,
		operation = verb,
		request_id = request_id,
		generation = identity.generation,
	}, { label = 'http_operation_done_report_failed' })
	local report_event = events_port and service_events.reporter(events_port, 'http_operation_done_report_failed')
		or function (ev) return service:_submit_event(ev, 'http_operation_done_report_failed', { fatal = true }) end

	local cancel_op = owner.caller_cancel_op and owner:caller_cancel_op() or nil

	local handle, err = scoped_work.start({
		lifetime_scope = service._scope,
		reaper_scope = service._scope,
		report_scope = service._scope,
		identity = identity,
		setup = setup_fn,
		run = run,
		report = report_event,
		cancel_op = cancel_op,
	})
	if not handle then
		local rec = service._state.operations[identity.operation_id]
		if rec then rec.state = 'completed'; rec.status = 'failed'; rec.primary = err or 'operation_start_failed' end
		service:_finish_request(request_id, 'failed', err or 'operation_start_failed')
		owner:finalise_unresolved(err or 'operation_start_failed')
		service._state.last_error = err or 'operation_start_failed'
		return true
	end
	service._state.operations[identity.operation_id].state = 'running'
	service._state.operations[identity.operation_id].handle = handle
	return true
end

return M
