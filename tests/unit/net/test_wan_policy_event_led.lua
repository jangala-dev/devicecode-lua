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
				mdm0 = { interface = 'mdm0', metric = 1, source = { kind = 'gsm-uplink', id = 'primary' } },
			},
			load_balancing = { speedtests = { enabled = true, probe_weight = 1, weight_scale = 100 } },
		},
		observed = { snapshot = { multiwan = { interfaces_by_semantic = { wan = { online = true }, mdm0 = { online = false } } } } },
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
	local due, reason = policy.speedtest_due(s, by_id.mdm0, { generation = 1, now = 10 })
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
	eq(by_id.mdm0.weight, 1)
	eq(by_id.mdm0.probe, true)
end

return tests
