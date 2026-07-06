local gsm = require 'services.gsm'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end

function tests.test_uplink_state_reports_locked_only_when_modem_state_is_locked()
	eq(gsm._test.uplink_state_for_modem(false, 'locked', 'sim-pin'), 'locked')
	eq(gsm._test.uplink_state_for_modem(false, 'locked', nil), 'locked')
	eq(gsm._test.uplink_state_for_modem(false, 'registered', 'sim-puk'), 'disconnected')
	eq(gsm._test.uplink_state_for_modem(false, 'registered', nil), 'disconnected')
	eq(gsm._test.uplink_state_for_modem(true, 'locked', 'sim-pin'), 'connected')
end

function tests.test_uplink_state_reports_disconnected_when_sim_is_absent()
	eq(gsm._test.uplink_state_for_modem(false, 'locked', nil, '--'), 'disconnected')
	eq(gsm._test.uplink_state_for_modem(false, 'registered', 'sim-puk', '--'), 'disconnected')
	eq(gsm._test.uplink_state_for_modem(true, 'locked', 'sim-pin', '--'), 'connected')
end

function tests.test_sim_payload_carries_lock_and_retry_details()
	local payload = gsm._test.build_sim_payload('present', 'sim-puk', {
		['sim-pin'] = 0,
		['sim-puk'] = 10,
	}, 'locked')

	eq(payload.state, 'locked')
	eq(payload.lock, 'sim-puk')
	eq(payload.lock_retries['sim-pin'], 0)
	eq(payload.lock_retries['sim-puk'], 10)
end

function tests.test_sim_payload_ignores_non_blocking_pin2_on_connected_modem()
	local payload = gsm._test.build_sim_payload('present', 'sim-pin2', {
		['sim-pin'] = 3,
		['sim-pin2'] = 3,
	}, 'connected')

	eq(payload.state, 'present')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

function tests.test_sim_payload_treats_connected_modem_as_present_when_sim_is_unknown()
	local payload = gsm._test.build_sim_payload(nil, nil, nil, 'connected')

	eq(payload.state, 'present')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

function tests.test_sim_payload_reports_locked_without_lock_detail_when_modem_locked()
	local payload = gsm._test.build_sim_payload('present', nil, nil, 'locked')

	eq(payload.state, 'locked')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

function tests.test_sim_payload_preserves_unlocked_presence()
	local payload = gsm._test.build_sim_payload('present', nil, nil, 'connected')

	eq(payload.state, 'present')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

return tests
