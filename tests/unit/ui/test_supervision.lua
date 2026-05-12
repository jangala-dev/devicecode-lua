-- tests/unit/ui/test_supervision.lua

local supervision = require 'services.ui.supervision'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end

function tests.test_service_core_component_ok_continues()
	local d = supervision.classify_service_component_done({}, {
		component = 'http_listener',
		status = 'ok',
		result = { status = 'stopped' },
	})
	assert_eq(d.class, 'normal_close')
	assert_eq(d.action, 'continue')
end

function tests.test_service_core_component_failure_fails_service()
	local d = supervision.classify_service_component_done({}, {
		component = 'read_model',
		status = 'failed',
		primary = 'boom',
	})
	assert_eq(d.class, 'failed')
	assert_eq(d.action, 'fail_service')
	assert_eq(d.reason, 'read_model failed: boom')
end

function tests.test_service_core_component_cancellation_fails_service()
	local d = supervision.classify_service_component_done({}, {
		component = 'http_listener',
		status = 'cancelled',
		primary = 'lost',
	})
	assert_eq(d.class, 'cancelled_unexpected')
	assert_eq(d.action, 'fail_service')
	assert_eq(d.reason, 'http_listener cancelled unexpectedly: lost')
end

return tests
