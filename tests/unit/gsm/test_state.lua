local gsm = require 'services.gsm'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end

local function new_test_modem()
	local retained = {}
	local unretained = {}
	local domain = {
		retain = function(_, topic, payload)
			retained[table.concat(topic, '/')] = payload
			return true
		end,
		unretain = function(_, topic)
			local key = table.concat(topic, '/')
			retained[key] = nil
			unretained[key] = true
			return true
		end,
	}
	local modem = setmetatable({
		id = 'test-modem',
		name = 'primary',
		device = '/dev/test-modem',
		connected = true,
		wwan_iface = 'wwan0',
		modem_state = 'connected',
		sim_state = 'present',
		info_values = {},
		info_observed_at = {},
		uplink_generation = 0,
		domain = domain,
		svc = { wall = function() return 100 end },
	}, gsm._test.GsmModem)

	return modem, retained, unretained
end

local function signal_event(access_techs, signal, observed_at)
	return {
		schema = 'devicecode.hal.modem.signal/1',
		access_techs = access_techs,
		signal = signal,
		observed_at = observed_at,
	}
end

function tests.test_uplink_state_uses_semantic_registered_state()
	eq(gsm._test.uplink_state_for_modem(false, 'locked', 'sim-pin'), 'locked')
	eq(gsm._test.uplink_state_for_modem(false, 'locked', nil), 'locked')
	eq(gsm._test.uplink_state_for_modem(false, 'registered', 'sim-puk'), 'registered')
	eq(gsm._test.uplink_state_for_modem(false, 'registered', nil), 'registered')
	eq(gsm._test.uplink_state_for_modem(true, 'locked', 'sim-pin'), 'locked')
end

function tests.test_uplink_state_reports_sim_absent_when_sim_is_absent()
	eq(gsm._test.uplink_state_for_modem(false, 'locked', nil, '--'), 'sim_absent')
	eq(gsm._test.uplink_state_for_modem(false, 'registered', 'sim-puk', '--'), 'sim_absent')
	eq(gsm._test.uplink_state_for_modem(true, 'locked', 'sim-pin', '--'), 'sim_absent')
end

function tests.test_sim_payload_carries_lock_and_retry_details()
	local payload = gsm._test.build_sim_payload('present', 'sim-puk', {
		['sim-pin'] = 0,
		['sim-puk'] = 10,
	}, 'locked')

	eq(payload.present, true)
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

	eq(payload.present, true)
	eq(payload.state, 'present')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

function tests.test_sim_payload_treats_connected_modem_as_present_when_sim_is_unknown()
	local payload = gsm._test.build_sim_payload(nil, nil, nil, 'connected')

	eq(payload.present, true)
	eq(payload.state, 'present')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

function tests.test_sim_payload_reports_locked_without_lock_detail_when_modem_locked()
	local payload = gsm._test.build_sim_payload('present', nil, nil, 'locked')

	eq(payload.present, true)
	eq(payload.state, 'locked')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

function tests.test_sim_payload_preserves_unlocked_presence()
	local payload = gsm._test.build_sim_payload('present', nil, nil, 'connected')

	eq(payload.present, true)
	eq(payload.state, 'present')
	eq(payload.lock, nil)
	eq(payload.lock_retries, nil)
end

function tests.test_sim_payload_reports_absent_explicitly()
	local payload = gsm._test.build_sim_payload('--', nil, nil, 'disabled')

	eq(payload.present, false)
	eq(payload.state, 'absent')
	eq(payload.legacy_state, '--')
	eq(payload.lock, nil)
end

function tests.test_canonical_signal_matches_current_access_tech()
	local signals = {
		lte = { rsrp = -96 },
		['5g'] = { rsrp = -103 },
		umts = { rssi = -82, rscp = -88 },
		gsm = { rssi = -78 },
	}

	local signal, tech = gsm._test.select_canonical_signal({ 'lte' }, signals)
	eq(tech, 'lte')
	eq(signal.rsrp, -96)

	signal, tech = gsm._test.select_canonical_signal({ 'umts' }, signals)
	eq(tech, 'umts')
	eq(signal.rscp, -88)

	signal, tech = gsm._test.select_canonical_signal({ 'gsm' }, signals)
	eq(tech, 'gsm')
	eq(signal.rssi, -78)
end

function tests.test_5g_nsa_prefers_5g_when_both_signal_sets_are_valid()
	local signals = {
		lte = { rsrp = -96 },
		['5g'] = { rsrp = -103 },
	}
	local signal, tech = gsm._test.select_canonical_signal({ 'lte', '5gnr' }, signals)
	eq(tech, '5g')
	eq(signal.rsrp, -103)
end

function tests.test_5g_nsa_selects_the_most_complete_signal_set()
	local signal, tech = gsm._test.select_canonical_signal({ 'lte', '5gnr' }, {
		lte = { rssi = -70, rsrp = -96, rsrq = -11 },
		['5g'] = { rsrp = -103, snr = 12 },
	})
	eq(tech, 'lte')
	eq(signal.rsrq, -11)

	signal, tech = gsm._test.select_canonical_signal({ 'lte', '5gnr' }, {
		lte = { rsrp = -96 },
		['5g'] = { rssi = -80, rsrp = -103, snr = 12 },
	})
	eq(tech, '5g')
	eq(signal.snr, 12)
end

function tests.test_signal_selection_ignores_fields_outside_the_completeness_set()
	local signal, tech = gsm._test.select_canonical_signal({ 'lte', '5gnr' }, {
		lte = { rssi = -70, ecio = -10, io = -80 },
		['5g'] = { rsrp = -103 },
	})
	-- Both candidates contain one canonical field. LTE's additional
	-- technology-specific fields must not make it appear more complete.
	eq(tech, '5g')
	eq(signal.rsrp, -103)
end

function tests.test_signal_selection_ignores_more_complete_inactive_techs()
	local signal, tech = gsm._test.select_canonical_signal({ 'lte' }, {
		lte = { rsrp = -96 },
		['5g'] = { rssi = -80, rsrp = -103, rsrq = -10, snr = 12 },
	})
	eq(tech, 'lte')
	eq(signal.rsrp, -96)
end

function tests.test_5g_nsa_falls_back_to_lte_when_5g_signal_is_unavailable()
	local signals = { lte = { rsrp = -96 } }
	local signal, tech = gsm._test.select_canonical_signal({ '5gnr', 'lte' }, signals)
	eq(tech, 'lte')
	eq(signal.rsrp, -96)
end

function tests.test_5g_sa_does_not_fall_back_to_an_unrelated_lte_signal()
	local signal, tech = gsm._test.select_canonical_signal({ '5gnr' }, { lte = { rsrp = -96 } })
	eq(signal, nil)
	eq(tech, '')
end

function tests.test_empty_signal_event_unretains_signal_and_omits_it_from_uplink()
	local modem, retained, unretained = new_test_modem()
	local accepted, err = modem:_accept_signal_event(signal_event({ 'lte' }, {
		lte = { rssi = -70, rsrp = -96, rsrq = -11, snr = 10 },
	}, 1))
	eq(accepted, true, err)
	eq(retained['modem/primary/signal'].rsrp, -96)

	accepted, err = modem:_accept_signal_event(signal_event({ 'lte' }, {}, 2))
	eq(accepted, true, err)
	eq(retained['modem/primary/signal'], nil)
	eq(unretained['modem/primary/signal'], true)
	eq(retained['uplink/primary'].signal, nil)
	eq(retained['uplink/primary'].access.signal_tech, nil)
end

function tests.test_incomplete_5g_event_retains_complete_lte_signal()
	local modem, retained = new_test_modem()
	local accepted, err = modem:_accept_signal_event(signal_event({ 'lte', '5gnr' }, {
		['5g'] = { rsrp = -103, snr = 12 },
		lte = { rssi = -70, rsrp = -96, rsrq = -11, snr = 10 },
	}, 1))
	eq(accepted, true, err)

	local signal = retained['modem/primary/signal']
	eq(signal.rssi, -70)
	eq(signal.rsrp, -96)
	eq(signal.rsrq, -11)
	eq(signal.snr, 10)
	eq(retained['uplink/primary'].signal.rsrp, -96)
	eq(retained['uplink/primary'].access.signal_tech, 'lte')
end

function tests.test_signal_bars_use_the_selected_signal_tech()
	local tech, value, field = gsm._test.select_signal_for_bars('lte', nil, -96, nil)
	eq(tech, 'lte')
	eq(value, -96)
	eq(field, 'rsrp')
end

return tests
