local registry = require 'services.http.registry'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

local function event_port(events)
	return {
		emit_required = function (_, ev)
			events[#events + 1] = ev
			return true, nil
		end,
	}
end

function M.test_registry_records_transfer_and_shutdown_termination()
	local events = {}
	local reg = registry.new({ events_port = event_port(events) })
	local handle = { closed = false, terminate = function (self, reason) self.closed = reason or true; return true end }
	local id = ok(reg:register('exchange', handle, { generation = 7 }))
	eq(reg:count('exchange'), 1)
	ok(reg:mark_transferred(id, 7))
	reg:terminate_all('shutdown')
	eq(handle.closed, 'shutdown')
	eq(reg:count('exchange'), 0)
	eq(events[1].kind, 'exchange_registered')
	eq(events[2].kind, 'exchange_transferred')
	eq(events[#events].kind, 'exchange_terminated')
end


function M.test_registry_can_report_through_service_event_port()
	local events = {}
	local port = {
		emit_required = function (_, ev)
			events[#events + 1] = ev
			return true, nil
		end,
	}
	local reg = registry.new({ events_port = port })
	local id = ok(reg:register('listener', { terminate = function () return true end }, { generation = 4 }))
	ok(reg:mark_transferred(id, 4))
	eq(events[1].kind, 'listener_registered')
	eq(events[2].kind, 'listener_transferred')
end

function M.test_registry_ignores_stale_generation_removal()
	local reg = registry.new()
	local id = ok(reg:register('listener', { terminate = function () return true end }, { generation = 1 }))
	local removed, err = reg:remove(id, 'stale', 2)
	eq(removed, false)
	eq(err, 'stale_handle')
	eq(reg:count('listener'), 1)
end


function M.test_registry_reserve_register_transfer_remove_is_stale_safe()
	local events = {}
	local reg = registry.new({ events_port = event_port(events) })
	local id = ok(reg:reserve('listener', { generation = 3 }))
	eq(reg:count('listener'), 0, 'reserved handles are not active')
	eq(#events, 0, 'reserve should not emit an active-handle event')
	local handle = { terminated = nil, terminate = function (self, reason) self.terminated = reason; return true end }
	local rid = ok(reg:register('listener', handle, { id = id, generation = 3 }))
	eq(rid, id)
	eq(reg:count('listener'), 1)
	ok(reg:mark_transferred(id, 3))
	local stale, serr = reg:remove(id, 'stale', 99)
	eq(stale, false)
	eq(serr, 'stale_handle')
	eq(reg:count('listener'), 1)
	ok(reg:terminate(id, 'shutdown', 3))
	eq(handle.terminated, 'shutdown')
	eq(reg:count('listener'), 0)
	eq(events[1].kind, 'listener_registered')
	eq(events[2].kind, 'listener_transferred')
	eq(events[3].kind, 'listener_terminated')
end

return M
