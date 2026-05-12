-- tests/unit/ui/test_service.lua

local service = require 'services.ui.service'
local busmod = require 'bus'
local authz = require 'devicecode.authz'
local run_fibers = require 'tests.support.run_fibers'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or 'expected true') end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

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

function tests.test_default_auth_opts_uses_admin_password_env()
	local opts = service._test.default_auth_opts({}, function (name)
		if name == 'DEVICECODE_UI_ADMIN_PASSWORD' then return 'e2e' end
	end)
	assert_eq(opts.users.admin.password, 'e2e')
	local principal = opts.users.admin.principal
	assert_not_nil(principal)
	assert_eq(principal.kind, 'user')
	assert_eq(principal.id, 'admin')
	assert_eq(principal.roles[1], 'admin')
end

function tests.test_default_admin_principal_is_authorized_on_runtime_bus()
	run_fibers.run(function ()
		local opts = service._test.default_auth_opts({}, function (name)
			if name == 'DEVICECODE_UI_ADMIN_PASSWORD' then return 'e2e' end
		end)
		local b = busmod.new({
			q_length = 4,
			s_wild = '+',
			m_wild = '#',
			authoriser = authz.new(),
		})
		local conn = b:connect({ principal = opts.users.admin.principal })
		local ok, err = pcall(function ()
			conn:bind({ 'cap', 'artifact-ingest', 'test', 'rpc', 'create' })
		end)
		if not ok then fail('default admin principal rejected by bus: ' .. tostring(err)) end
	end)
end

function tests.test_default_auth_opts_does_not_override_explicit_auth()
	local explicit = { users = { operator = 'secret' } }
	local opts = service._test.default_auth_opts({ auth_opts = explicit }, function ()
		return 'e2e'
	end)
	assert_eq(opts, explicit)

	opts = service._test.default_auth_opts({ auth = {} }, function ()
		return 'e2e'
	end)
	assert_eq(opts, nil)
end

function tests.test_default_update_opts_create_mcu_job_for_uploads()
	local opts = service._test.default_update_opts({})
	assert_eq(opts.create_job, true)
	assert_eq(opts.start_job, true)
	assert_eq(opts.component, 'mcu')
end

function tests.test_default_update_opts_preserves_explicit_upload_job_policy()
	local opts = service._test.default_update_opts({
		update = {
			create_job = false,
			start_job = false,
			component = 'cm5',
		},
	})
	assert_eq(opts.create_job, false)
	assert_eq(opts.start_job, false)
	assert_eq(opts.component, 'cm5')
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

function tests.test_publish_summary_uses_read_model_counts_not_full_snapshot()
	local retained = {}
	local state = base_state()
	state.conn = {
		retain = function (_, topic, payload)
			retained[table.concat(topic, '/')] = payload
			return true
		end,
	}
	state.model = {
		version = function () return 7 end,
		count = function (_, pattern)
			if pattern ~= nil and pattern[1] == 'svc' then return 2 end
			return 5
		end,
		is_closed = function () return false end,
		why = function () return nil end,
		snapshot = function () error('snapshot should not be materialised') end,
	}
	state.sessions = { count = function () return 3 end }
	state.active_requests = 0
	state.rejected_requests = 0

	service._test.publish_summary(state)

	assert_eq(retained['state/ui/summary'].version, 7)
	assert_eq(retained['state/ui/summary'].services, 2)
	assert_eq(retained['state/ui/summary'].sessions, 3)
	assert_eq(retained['state/ui/read-model'].items, 5)
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
