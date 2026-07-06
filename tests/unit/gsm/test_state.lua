local gsm = require 'services.gsm'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end

function tests.test_uplink_state_reports_locked_when_modem_or_sim_lock_is_locked()
	eq(gsm._test.uplink_state_for_modem(false, 'locked', 'sim-pin'), 'locked')
	eq(gsm._test.uplink_state_for_modem(false, 'locked', nil), 'locked')
	eq(gsm._test.uplink_state_for_modem(false, 'registered', 'sim-puk'), 'locked')
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
	})

	eq(payload.state, 'locked')
	eq(payload.lock, 'sim-puk')
	eq(payload.lock_retries['sim-pin'], 0)
	eq(payload.lock_retries['sim-puk'], 10)
end

function tests.test_sim_payload_preserves_unlocked_presence()
	local payload = gsm._test.build_sim_payload('present', nil, nil)

	eq(payload.state, 'present')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

return tests
