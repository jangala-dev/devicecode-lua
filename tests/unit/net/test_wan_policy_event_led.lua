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
				wan = { id = 'wan', interface = 'wan', state = 'online', usable = true },
				modem_primary = { id = 'modem_primary', interface = 'modem_primary', state = 'offline', usable = false },
			},
		},
		wan_runtime = { speedtests = {} },
		sources = { gsm_uplinks = { primary = { linux = { ifname = 'wwan1' } } } },
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
	s.wan_runtime.speedtests.wan = { state = 'done', generation = 1, ok = true, peak_mbps = 80, interface = 'wan' }
	local weights = assert(policy.compute_weights(s, 1))
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
	s.wan_runtime.speedtests.wan = {
		state = 'done',
		generation = 1,
		ok = true,
		peak_mbps = 80,
		last_success_mbps = 80,
		completed_at = 10,
		interface = 'wan',
	}
	s.wan_runtime.speedtests.modem_primary = {
		state = 'done',
		generation = 2,
		ok = true,
		peak_mbps = 20,
		last_success_mbps = 20,
		completed_at = 20,
		interface = 'modem_primary',
	}
	local uplinks = policy.collect_uplinks(s)
	local by_uplink = {}
	for _, u in ipairs(uplinks) do by_uplink[u.uplink_id] = u end
	local due, reason = policy.speedtest_due(s, by_uplink.wan, { generation = 2, now = 30 })
	eq(due, false)
	eq(reason, 'fresh')

	local weights = assert(policy.compute_weights(s, 2, { now = 30 }))
	local by_id = {}
	for _, m in ipairs(weights) do by_id[m.id] = m end
	eq(by_id.wan.weight, 80)
	eq(by_id.wan.probe, false)
	eq(by_id.modem_primary.weight, 20)

	local expired_weights = assert(policy.compute_weights(s, 2, { now = 130 }))
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
	s.wan_runtime.speedtests.wan = {
		state = 'failed',
		generation = 2,
		ok = false,
		last_attempt = { state = 'failed', reason = 'counter_unavailable', completed_at = 30 },
		last_success = { mbps = 80, completed_at = 10 },
		last_success_mbps = 80,
		last_success_at = 10,
		interface = 'wan',
	}
	s.wan_runtime.speedtests.modem_primary = {
		state = 'ok',
		generation = 2,
		ok = true,
		last_success = { mbps = 20, completed_at = 20 },
		interface = 'modem_primary',
	}

	local weights = assert(policy.compute_weights(s, 2, { now = 30 }))
	local by_id = {}
	for _, m in ipairs(weights) do by_id[m.id] = m end
	eq(by_id.wan.weight, 80)
	eq(by_id.wan.probe, false)
	eq(by_id.modem_primary.weight, 20)
end

return tests
