-- tests/unit/net/test_wan_policy_event_led.lua

local policy = require 'services.net.wan_policy'

local tests = {}
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg) if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

local function snapshot()
	return {
		generation = 1,
		wan = {
			members = {
				wan = { interface = 'wan', metric = 1 },
				modem_primary = { interface = 'modem_primary', metric = 1, source = { kind = 'gsm-uplink', id = 'primary' } },
			},
			load_balancing = { speedtests = { enabled = true, probe_weight = 1, weight_scale = 100 } },
		},
		backhaul = {
			uplinks = {
				wan = { id = 'wan', interface = 'wan', device = 'eth1', state = 'online', usable = true, path_address = { family = 'ipv4', address = '203.0.113.10' } },
				modem_primary = { id = 'modem_primary', interface = 'modem_primary', device = 'wwan1', state = 'offline', usable = false, path_address = { family = 'ipv4', address = '10.1.2.3' } },
			},
		},
		wan_runtime = { speedtests = {} },
		sources = { gsm_uplinks = { primary = { linux = { ifname = 'wwan1' } } } },
	}
end

local function uplinks_by_id(s)
    local out = {}
    for _, u in ipairs(policy.collect_uplinks(s)) do out[u.uplink_id] = u end
    return out
end

local function keyed_success(s, uplink_id, mbps, completed_at)
    local uplink = uplinks_by_id(s)[uplink_id]
    local measurement = assert(policy.measurement(s, uplink))
    return {
        state = 'ok',
        generation = s.generation,
        ok = true,
        peak_mbps = mbps,
        last_success_mbps = mbps,
        completed_at = completed_at,
        interface = uplink.request.interface,
        measurement_key = measurement.key,
        measurement = measurement,
        last_success = { mbps = mbps, completed_at = completed_at, measurement_key = measurement.key, measurement = measurement },
    }
end

function tests.test_only_observed_online_uplink_is_due()
	local s = snapshot()
	local uplinks = policy.collect_uplinks(s)
	local by_id = {}
	for _, u in ipairs(uplinks) do by_id[u.uplink_id] = u end
	ok(policy.speedtest_due(s, by_id.wan, { generation = 1, now = 10 }))
	local due, reason = policy.speedtest_due(s, by_id.modem_primary, { generation = 1, now = 10 })
	eq(due, false)
	eq(reason, 'not_online')
end

function tests.test_weights_include_probe_members_after_one_measurement()
	local s = snapshot()
	s.wan_runtime.speedtests.wan = keyed_success(s, 'wan', 80, 10)
	local weights = assert(policy.compute_weights(s, 1, { now = 20 }))
	eq(#weights, 2)
	local by_id = {}
	for _, m in ipairs(weights) do by_id[m.id] = m end
	eq(by_id.wan.weight, 100)
	eq(by_id.modem_primary.weight, 1)
	eq(by_id.modem_primary.probe, true)
end

function tests.test_fresh_previous_generation_success_is_used_for_weights()
    local s = snapshot()
    s.generation = 2
    s.wan.load_balancing.speedtests.interval_s = 100
    s.backhaul.uplinks.modem_primary.state = 'online'
    s.backhaul.uplinks.modem_primary.usable = true
    s.wan_runtime.speedtests.wan = keyed_success(s, 'wan', 80, 10)
    s.wan_runtime.speedtests.wan.generation = 1
    s.wan_runtime.speedtests.modem_primary = keyed_success(s, 'modem_primary', 20, 20)
    s.wan_runtime.speedtests.modem_primary.generation = 2
    local uplinks = policy.collect_uplinks(s)
    local by_uplink = {}
    for _, u in ipairs(uplinks) do by_uplink[u.uplink_id] = u end
    local due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 2, now = 30 })
    eq(due, false)
    eq(reason, 'fresh_same_path')

    local weights = assert(policy.compute_weights(s, 2, { now = 30 }))
    local by_id = {}
    for _, m in ipairs(weights) do by_id[m.id] = m end
    eq(by_id.wan.weight, 80)
    eq(by_id.wan.probe, false)
    eq(by_id.modem_primary.weight, 20)

    local expired_weights = assert(policy.compute_weights(s, 2, { now = 119 }))
    local expired_by_id = {}
    for _, m in ipairs(expired_weights) do expired_by_id[m.id] = m end
    eq(expired_by_id.wan.weight, 1)
    eq(expired_by_id.wan.probe, true)
    eq(expired_by_id.modem_primary.weight, 100)
end


function tests.test_failed_latest_speedtest_keeps_fresh_last_success_for_weights()
    local s = snapshot()
    s.generation = 2
    s.wan.load_balancing.speedtests.interval_s = 100
    s.backhaul.uplinks.modem_primary.state = 'online'
    s.backhaul.uplinks.modem_primary.usable = true
    s.wan_runtime.speedtests.wan = keyed_success(s, 'wan', 80, 10)
    s.wan_runtime.speedtests.wan.state = 'failed'
    s.wan_runtime.speedtests.wan.ok = false
    s.wan_runtime.speedtests.wan.last_attempt = { state = 'failed', reason = 'counter_unavailable', completed_at = 30 }
    s.wan_runtime.speedtests.modem_primary = keyed_success(s, 'modem_primary', 20, 20)

    local weights = assert(policy.compute_weights(s, 2, { now = 30 }))
    local by_id = {}
    for _, m in ipairs(weights) do by_id[m.id] = m end
    eq(by_id.wan.weight, 80)
    eq(by_id.wan.probe, false)
    eq(by_id.modem_primary.weight, 20)
end



function tests.test_weights_fall_back_to_mwan3_online_members_without_speedtest_success()
    local s = snapshot()
    local weights = assert(policy.compute_weights(s, 1, { now = 30 }))
    eq(#weights, 1)
    eq(weights[1].id, 'wan')
    eq(weights[1].weight, 100)
    eq(weights[1].probe, true)
    eq(weights[1].reason, 'no_successful_speedtests')
end

function tests.test_default_speedtest_interval_is_six_hours()
	local s = snapshot()
	s.generation = 2
	s.wan_runtime.speedtests.wan = keyed_success(s, 'wan', 80, 10)
	s.wan_runtime.speedtests.wan.generation = 1
	local uplinks = policy.collect_uplinks(s)
	local by_uplink = {}
	for _, u in ipairs(uplinks) do by_uplink[u.uplink_id] = u end

	local due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 2, now = 10 + (6 * 60 * 60) - 1 })
	eq(due, false)
	eq(reason, 'fresh_same_path')

	due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 2, now = 10 + (6 * 60 * 60) + 1 })
	eq(due, true)
	eq(reason, 'due')
end


function tests.test_speedtest_request_duration_is_capped_at_one_second()
	local s = snapshot()
	s.wan.members.wan.speedtest_duration_s = 8
	local uplinks = policy.collect_uplinks(s)
	local by_uplink = {}
	for _, u in ipairs(uplinks) do by_uplink[u.uplink_id] = u end
	eq(by_uplink.wan.request.max_duration_s, 1)

	s.wan.members.wan.speedtest_duration_s = 0.5
	uplinks = policy.collect_uplinks(s)
	by_uplink = {}
	for _, u in ipairs(uplinks) do by_uplink[u.uplink_id] = u end
	eq(by_uplink.wan.request.max_duration_s, 0.5)
end


function tests.test_ip_change_invalidates_fresh_measurement()
    local s = snapshot()
    s.wan.load_balancing.speedtests.interval_s = 100
    s.wan_runtime.speedtests.wan = keyed_success(s, 'wan', 80, 10)
    s.backhaul.uplinks.wan.path_address.address = '198.51.100.42'
    local by_uplink = uplinks_by_id(s)
    local due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 2, now = 30 })
    eq(due, true)
    eq(reason, 'path_changed_ip')
end


function tests.test_modem_ip_change_invalidates_fresh_measurement()
    local s = snapshot()
    s.wan.load_balancing.speedtests.interval_s = 100
    s.backhaul.uplinks.modem_primary.state = 'online'
    s.backhaul.uplinks.modem_primary.usable = true
    s.wan_runtime.speedtests.modem_primary = keyed_success(s, 'modem_primary', 20, 10)
    s.backhaul.uplinks.modem_primary.path_address.address = '10.9.8.7'
    local by_uplink = uplinks_by_id(s)
    local due, reason = policy.speedtest_due(s, by_uplink.modem_primary, { generation = 2, now = 30 })
    eq(due, true)
    eq(reason, 'path_changed_ip')
end

function tests.test_online_uplink_without_ip_still_runs_first_measurement()
    local s = snapshot()
    s.backhaul.uplinks.wan.path_address = nil
    local by_uplink = uplinks_by_id(s)
    local due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 1, now = 10 })
    eq(due, true)
    eq(reason, 'due')
    local measurement = assert(policy.measurement(s, by_uplink.wan))
    eq(measurement.address_family, 'unknown')
    eq(measurement.address, 'unknown')
end

function tests.test_fresh_weak_measurement_is_reused_when_ip_later_appears()
    local s = snapshot()
    s.wan.load_balancing.speedtests.interval_s = 100
    s.backhaul.uplinks.wan.path_address = nil
    s.wan_runtime.speedtests.wan = keyed_success(s, 'wan', 80, 10)
    s.backhaul.uplinks.wan.path_address = { family = 'ipv4', address = '203.0.113.10' }
    local by_uplink = uplinks_by_id(s)
    local due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 2, now = 30 })
    eq(due, false)
    eq(reason, 'fresh_weak_path')
end

function tests.test_speedtest_retry_delay_uses_configured_exponential_backoff()
    local s = snapshot()
    s.wan.load_balancing.speedtests.retry_after_s = 10
    s.wan.load_balancing.speedtests.retry_max_s = 60
    eq(policy.speedtest_retry_delay_s(s, { failure_count = 1 }), 10)
    eq(policy.speedtest_retry_delay_s(s, { failure_count = 2 }), 20)
    eq(policy.speedtest_retry_delay_s(s, { failure_count = 3 }), 40)
    eq(policy.speedtest_retry_delay_s(s, { failure_count = 4 }), 60)
end

function tests.test_speedtest_retry_delay_defaults_to_ten_seconds()
    local s = snapshot()
    eq(policy.speedtest_retry_delay_s(s, { failure_count = 1 }), 10)
end


function tests.test_retry_backoff_only_suppresses_same_path()
    local s = snapshot()
    local by_uplink = uplinks_by_id(s)
    local measurement = assert(policy.measurement(s, by_uplink.wan))
    s.wan_runtime.speedtests.wan = {
        state = 'failed', ok = false, measurement_key = measurement.key,
        failure_count = 1, retry_after = 40,
    }
    local due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 1, now = 20 })
    eq(due, false)
    eq(reason, 'retry_later')

    s.backhaul.uplinks.wan.path_address.address = '198.51.100.42'
    by_uplink = uplinks_by_id(s)
    due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 1, now = 20 })
    eq(due, true)
    eq(reason, 'due')
end

return tests
