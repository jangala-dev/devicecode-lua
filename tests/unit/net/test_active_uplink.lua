-- tests/unit/net/test_active_uplink.lua
--
-- Which uplink is carrying traffic under strict failover (metric 1/2/3).

local active_uplink = require 'services.net.active_uplink'

local tests = {}
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function rec(id, metric, state)
	return {
		id = id, interface = id, metric = metric,
		state = state, usable = state == 'online', observed = state ~= 'unknown',
	}
end

-- BigBox shape: wired WAN, then modem 1, then modem 2.
local function uplinks(wan, modem_primary, modem_secondary)
	return {
		wan = rec('wan', 1, wan),
		modem_primary = rec('modem_primary', 2, modem_primary),
		modem_secondary = rec('modem_secondary', 3, modem_secondary),
	}
end

local function snapshot(opts)
	opts = opts or {}
	return {
		wan = {
			last_resort = opts.last_resort,
			load_balancing = { policy = opts.policy_name or 'balanced' },
		},
		observed = { snapshot = { multiwan = opts.multiwan } },
	}
end

-- mwan3 shortens long member names; HAL keeps the mwan3 name in .interface.
local function multiwan_with_policies(policies, by_semantic)
	return {
		interfaces_by_semantic = {
			wan = { interface = 'wan' },
			modem_primary = { interface = 'mopri79e' },
			modem_secondary = { interface = 'mosec892' },
		},
		policies = policies,
		policies_by_semantic = by_semantic,
	}
end

local function has(list, v)
	for i = 1, #(list or {}) do if list[i] == v then return true end end
	return false
end

function tests.test_wan_only_is_active()
	local a = active_uplink.select(snapshot(), uplinks('online', 'offline', 'offline'))
	eq(a.status, 'uplink')
	eq(a.uplink_id, 'wan')
	eq(a.interface, 'wan')
	eq(a.source, 'lowest_metric')
	eq(#a.uplink_ids, 1)
end

function tests.test_wan_and_modem_online_wan_is_active_modem_is_standby()
	local a = active_uplink.select(snapshot(), uplinks('online', 'online', 'offline'))
	eq(a.status, 'uplink')
	eq(a.uplink_id, 'wan')
	ok(not has(a.uplink_ids, 'modem_primary'), 'modem must be standby')
end

function tests.test_wan_down_fails_over_to_first_modem()
	local a = active_uplink.select(snapshot(), uplinks('offline', 'online', 'online'))
	eq(a.status, 'uplink')
	eq(a.uplink_id, 'modem_primary')
	eq(a.metric, 2)
end

function tests.test_wan_and_first_modem_down_uses_second_modem()
	local a = active_uplink.select(snapshot(), uplinks('offline', 'offline', 'online'))
	eq(a.uplink_id, 'modem_secondary')
end

function tests.test_all_down_reports_last_resort_by_default()
	local a = active_uplink.select(snapshot(), uplinks('offline', 'offline', 'offline'))
	eq(a.status, 'last_resort')
	eq(a.uplink_id, nil)
	eq(#a.uplink_ids, 0)

	a = active_uplink.select(snapshot({ last_resort = 'default' }), uplinks('offline', 'offline', 'offline'))
	eq(a.status, 'last_resort')
end

function tests.test_all_down_reports_none_when_last_resort_drops_traffic()
	for _, lr in ipairs({ 'unreachable', 'blackhole' }) do
		local a = active_uplink.select(snapshot({ last_resort = lr }), uplinks('offline', 'offline', 'offline'))
		eq(a.status, 'none', lr)
		eq(a.uplink_id, nil)
	end
end

function tests.test_nothing_observed_yet_is_unknown()
	local a = active_uplink.select(snapshot(), uplinks('unknown', 'unknown', 'unknown'))
	eq(a.status, 'unknown')
	eq(a.uplink_id, nil)
end

function tests.test_no_members_is_none()
	local a = active_uplink.select(snapshot(), {})
	eq(a.status, 'none')
end

function tests.test_semantic_mwan3_policy_wins_over_metric_order()
	local mw = multiwan_with_policies(nil, {
		ipv4 = { balanced = { { interface = 'modem_primary', percent = 100 } } },
	})
	local a = active_uplink.select(snapshot({ multiwan = mw }), uplinks('online', 'online', 'offline'))
	eq(a.status, 'uplink')
	eq(a.uplink_id, 'modem_primary')
	eq(a.source, 'mwan3_policy')
end

function tests.test_raw_mwan3_policy_names_are_mapped_back_to_members()
	local mw = multiwan_with_policies({
		ipv4 = { balanced = { { interface = 'mopri79e', percent = 100 } } },
	})
	local a = active_uplink.select(snapshot({ multiwan = mw }), uplinks('online', 'online', 'offline'))
	eq(a.uplink_id, 'modem_primary')
	eq(a.source, 'mwan3_policy')
end

function tests.test_mwan3_policy_uses_configured_policy_name()
	local mw = multiwan_with_policies(nil, {
		ipv4 = {
			balanced = { { interface = 'wan', percent = 100 } },
			wired_only = { { interface = 'modem_secondary', percent = 100 } },
		},
	})
	local snap = snapshot({ multiwan = mw, policy_name = 'wired_only' })
	local a = active_uplink.select(snap, uplinks('online', 'online', 'online'))
	eq(a.uplink_id, 'modem_secondary')
end

function tests.test_mwan3_policy_with_only_default_is_last_resort()
	local mw = multiwan_with_policies(nil, { ipv4 = { balanced = { { interface = 'default', percent = 100 } } } })
	local a = active_uplink.select(snapshot({ multiwan = mw }), uplinks('offline', 'offline', 'offline'))
	eq(a.status, 'last_resort')
	eq(a.source, 'mwan3_policy')
end

function tests.test_mwan3_policy_with_only_unreachable_is_none()
	local mw = multiwan_with_policies(nil, { ipv4 = { balanced = { { interface = 'unreachable' } } } })
	local a = active_uplink.select(snapshot({ multiwan = mw }), uplinks('offline', 'offline', 'offline'))
	eq(a.status, 'none')
end

function tests.test_unrecognised_or_empty_policy_falls_back_to_metric_order()
	local shapes = {
		{ ipv4 = { balanced = {} } },
		{ ipv4 = { balanced = 'wan (100%)' } },
		{ ipv4 = { balanced = { { interface = 'not_a_member', percent = 100 } } } },
		{ ipv4 = 'garbage' },
		'garbage',
	}
	for i, policies in ipairs(shapes) do
		local mw = multiwan_with_policies(policies)
		local a = active_uplink.select(snapshot({ multiwan = mw }), uplinks('offline', 'online', 'online'))
		eq(a.uplink_id, 'modem_primary', 'shape ' .. i)
		eq(a.source, 'lowest_metric', 'shape ' .. i)
	end
end

function tests.test_policy_members_with_zero_percent_are_not_in_use()
	local mw = multiwan_with_policies(nil, { ipv4 = { balanced = {
		{ interface = 'wan', percent = 0 },
		{ interface = 'modem_primary', percent = 100 },
	} } })
	local a = active_uplink.select(snapshot({ multiwan = mw }), uplinks('online', 'online', 'offline'))
	eq(a.uplink_id, 'modem_primary')
	ok(not has(a.uplink_ids, 'wan'), 'zero-percent member is not carrying traffic')
end

function tests.test_load_balanced_tier_lists_every_member_and_picks_deterministically()
	local ups = uplinks('online', 'online', 'offline')
	ups.modem_primary.metric = 1
	local a = active_uplink.select(snapshot(), ups)
	eq(a.uplink_id, 'modem_primary', 'ties break on id')
	eq(#a.uplink_ids, 2)
	ok(has(a.uplink_ids, 'wan') and has(a.uplink_ids, 'modem_primary'), 'both members share traffic')

	local mw = multiwan_with_policies(nil, { ipv4 = { balanced = {
		{ interface = 'wan', percent = 70 },
		{ interface = 'modem_primary', percent = 30 },
	} } })
	a = active_uplink.select(snapshot({ multiwan = mw }), ups)
	eq(a.uplink_id, 'wan', 'highest percent carries most traffic')
	eq(#a.uplink_ids, 2)
end

function tests.test_online_but_unusable_is_not_active()
	local ups = uplinks('online', 'online', 'offline')
	ups.wan.usable = false
	local a = active_uplink.select(snapshot(), ups)
	eq(a.uplink_id, 'modem_primary')
end

function tests.test_changed_compares_status_and_ids()
	local a = active_uplink.select(snapshot(), uplinks('online', 'online', 'offline'))
	local b = active_uplink.select(snapshot(), uplinks('offline', 'online', 'offline'))
	eq(active_uplink.changed(a, a), false)
	eq(active_uplink.changed(a, b), true)
	eq(active_uplink.changed(nil, a), true)
	eq(active_uplink.changed(nil, nil), false)
end

function tests.test_policy_interface_names_resolve_by_interface_before_member_id()
	-- Member ids and interface names are separate namespaces: here member "wan"
	-- uses the modem interface and member "primary" uses the wired "wan" interface.
	local ups = {
		primary = { id = 'primary', interface = 'wan', metric = 1, state = 'online', usable = true },
		wan = { id = 'wan', interface = 'modem_primary', metric = 2, state = 'online', usable = true },
	}
	local mw = { interfaces_by_semantic = {
		wan = { interface = 'wan' }, modem_primary = { interface = 'mopri79e' },
	} }
	mw.policies_by_semantic = { ipv4 = { balanced = { { interface = 'wan', percent = 100 } } } }
	local a = active_uplink.select(snapshot({ multiwan = mw }), ups)
	eq(a.uplink_id, 'primary', 'semantic policy names are interfaces')
	eq(a.interface, 'wan')

	mw.policies_by_semantic = nil
	mw.policies = { ipv4 = { balanced = { { interface = 'mopri79e', percent = 100 } } } }
	a = active_uplink.select(snapshot({ multiwan = mw }), ups)
	eq(a.uplink_id, 'wan', 'raw mwan3 names map to interfaces, then to members')
	eq(a.interface, 'modem_primary')
end

return tests
