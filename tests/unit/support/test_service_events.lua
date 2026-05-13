local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'

local service_events = require 'devicecode.support.service_events'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end

function tests.test_port_stamps_identity_and_preserves_event_fields()
	fibers.run(function ()
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local port = service_events.port(tx, {
			service_id = 'svc',
			source = 'component',
			source_id = 'c1',
			generation = 7,
		})

		assert_true(port:emit_required({ kind = 'changed', generation = 8, value = 42 }))
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'changed')
		assert_eq(ev.service_id, 'svc')
		assert_eq(ev.source, 'component')
		assert_eq(ev.source_id, 'c1')
		assert_eq(ev.generation, 8)
		assert_eq(ev.value, 42)
	end)
end

function tests.test_route_events_are_marked_for_mixed_request_queues()
	fibers.run(function ()
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local port = service_events.port(tx, { service_id = 'svc' }, { mark_route_events = true })
		assert_true(port:emit_required('service_active_snapshot', { snapshot = nil }))
		local ev = fibers.perform(rx:recv_op())
		assert_true(service_events.is_route_event(ev))
		assert_eq(ev.kind, 'service_active_snapshot')
	end)
end


function tests.test_wrap_stamps_identity_over_existing_event_port()
	local captured
	local target = {
		emit_required = function (_, ev, label)
			captured = { ev = ev, label = label }
			return true, nil
		end,
	}
	local port = service_events.wrap(target, {
		service_id = 'svc',
		source = 'child',
		source_id = 'c2',
	}, { label = 'child_report_failed' })
	assert_true(port:emit_required({ kind = 'done' }))
	assert_eq(captured.ev.kind, 'done')
	assert_eq(captured.ev.service_id, 'svc')
	assert_eq(captured.ev.source, 'child')
	assert_eq(captured.ev.source_id, 'c2')
	assert_eq(captured.label, 'child_report_failed')
end

return tests
