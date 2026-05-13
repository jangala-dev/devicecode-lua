-- tests/unit/ui/test_service.lua

local service = require 'services.ui.service'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or 'expected true') end end

local function base_state()
	return {
		components = {
			read_model = { status = 'running' },
			http_listener = { status = 'running' },
		},
		service_status = 'running',
		read_model_status = 'running',
		listener_status = 'running',
	}
end

function tests.test_records_component_completion_before_policy()
	local state = base_state()
	local decision = service._test.reduce_event(state, {
		kind = 'ui_component_done',
		component = 'read_model',
		status = 'ok',
		result = { status = 'stopped' },
	})
	assert_true(decision.publish)
	assert_eq(state.components.read_model.status, 'ok')
	assert_eq(state.read_model_status, 'ok')
end

function tests.test_read_model_failure_marks_service_failed()
	local state = base_state()
	local decision = service._test.reduce_event(state, {
		kind = 'ui_component_done',
		component = 'read_model',
		status = 'failed',
		primary = 'boom',
	})
	assert_true(decision.publish)
	assert_eq(decision.fail, 'read_model failed: boom')
	assert_eq(state.service_status, 'failed')
	assert_eq(state.last_error, 'read_model failed: boom')
	assert_eq(state.components.read_model.status, 'failed')
end

function tests.test_http_listener_failure_marks_service_failed()
	local state = base_state()
	local decision = service._test.reduce_event(state, {
		kind = 'ui_component_done',
		component = 'http_listener',
		status = 'failed',
		primary = 'listen failed',
	})
	assert_eq(decision.fail, 'http_listener failed: listen failed')
	assert_eq(state.service_status, 'failed')
	assert_eq(state.listener_status, 'failed')
end

function tests.test_stale_component_completion_is_ignored()
	local state = base_state()
	service._test.reduce_event(state, {
		kind = 'ui_component_done',
		component = 'read_model',
		status = 'ok',
		result = { status = 'stopped' },
	})
	local decision = service._test.reduce_event(state, {
		kind = 'ui_component_done',
		component = 'read_model',
		status = 'failed',
		primary = 'late',
	})
	assert_eq(next(decision), nil)
	assert_eq(state.components.read_model.status, 'ok')
end



function tests.test_publish_summary_fails_on_retain_failure()
	local state = base_state()
	state.conn = {
		retain = function () return nil, 'retain_failed' end,
	}
	state.sessions = { count = function () return 0 end }
	state.active_requests = 0
	state.rejected_requests = 0

	local ok, err = pcall(function ()
		service._test.publish_summary(state)
	end)

	if ok then fail('expected publish_summary to fail') end
	if not tostring(err):find('retain_failed', 1, true) then
		fail('expected retain failure, got ' .. tostring(err))
	end
end

function tests.test_session_events_are_first_class_service_events()
	local state = base_state()
	local decision = service._test.reduce_event(state, {
		kind = 'session_created',
		session_id = 's1',
		count = 1,
	})
	assert_true(decision.publish)
	assert_eq(state.last_session_event.kind, 'session_created')
	assert_eq(state.last_session_event.session_id, 's1')

	decision = service._test.reduce_event(state, {
		kind = 'session_pruned',
		session_ids = { 's1' },
		count = 0,
	})
	assert_true(decision.publish)
	assert_eq(state.last_session_event.kind, 'session_pruned')
end



function tests.test_stale_http_listener_request_events_are_ignored()
	local state = base_state()
	state.listener_generation = 3
	state.active_requests = 0
	state.rejected_requests = 0

	local decision = service._test.reduce_event(state, {
		kind = 'http_request_started',
		generation = 2,
		listener_id = 'http_listener:2',
		request_id = 'old',
		active_requests = 1,
	})
	assert_eq(next(decision), nil)
	assert_eq(state.active_requests, 0)

	decision = service._test.reduce_event(state, {
		kind = 'http_request_started',
		generation = 3,
		listener_id = 'http_listener:3',
		request_id = 'new',
		active_requests = 1,
	})
	assert_true(decision.publish)
	assert_eq(state.active_requests, 1)
end

function tests.test_cleanup_error_recording_is_explicit_and_non_throwing()
	local state = base_state()
	local rec = service._test.record_cleanup_error(state, 'ui_summary_unretain_failed', 'unretain_failed')
	assert_eq(rec.kind, 'ui_summary_unretain_failed')
	assert_eq(rec.err, 'unretain_failed')
	assert_eq(state.last_cleanup_error, rec)
end

return tests
