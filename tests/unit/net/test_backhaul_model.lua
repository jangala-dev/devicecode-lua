-- tests/unit/net/test_backhaul_model.lua

local backhaul = require 'services.net.backhaul_model'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end return v end

function tests.test_reduces_hal_multiwan_facts_to_semantic_backhaul()
	local model = backhaul.reduce({
		segments = {
			wan = { kind = 'wan', vlan = { id = 4 } },
		},
		wan = { configured_members = { wan = { interface = 'wan', metric = 10 } } },
		observed = {
			snapshot = {
				multiwan = {
					backend = 'openwrt',
					source = 'mwan3',
					interfaces_by_semantic = {
						wan = {
							interface = 'wan',
							ifname = 'eth0.2',
							state = 'online',
							usable = true,
							uptime_s = 123,
							age_s = 4,
							metric = 10,
						},
					},
				},
				live = {
					interfaces = {
						wan = { ipv4 = { { address = '203.0.113.10', mask = 24 } } },
					},
				},
			},
		},
	}, { now = 42 })

	eq(model.state, 'ok')
	local wan = ok(model.uplinks.wan, 'wan uplink expected')
	eq(wan.state, 'online')
	eq(wan.usable, true)
	eq(wan.uptime_s, 123)
	eq(wan.source.kind, 'host-multiwan')
	eq(wan.source.tool, 'mwan3')
	eq(wan.status_source.tool, 'mwan3')
	eq(wan.link.kind, 'wired')
	eq(wan.link.vlan, 4)
	eq(wan.path_address.address, '203.0.113.10')
end


function tests.test_backhaul_uses_mwan3_for_status_and_endpoint_for_device_name()
	local model = backhaul.reduce({
		interfaces = {
			wan = { endpoint = { ifname = 'vl-wan' } },
		},
		wan = { configured_members = { wan = { interface = 'wan', metric = 10 } } },
		observed = {
			snapshot = {
				multiwan = {
					backend = 'openwrt',
					source = 'mwan3',
					interfaces_by_semantic = {
						wan = { interface = 'wan', state = 'online', usable = true },
					},
				},
			},
		},
	}, { now = 42 })

	local wan = ok(model.uplinks.wan, 'wan uplink expected')
	eq(wan.state, 'online')
	eq(wan.usable, true)
	eq(wan.ifname, 'vl-wan')
	eq(wan.source.tool, 'mwan3')
	eq(wan.status_source.tool, 'mwan3')
end

function tests.test_gsm_uplink_uses_mwan3_status_not_gsm_connection_state()
	local model = backhaul.reduce({
		wan = {
			configured_members = {
				gsm_primary = { interface = 'modem_primary', source = { kind = 'gsm-uplink', id = 'primary' } },
			},
		},
		sources = {
			gsm_uplinks = {
				primary = {
					state = 'sim_absent',
					connected = false,
					linux = { ifname = 'wwan0' },
				},
			},
		},
		observed = {
			snapshot = {
				multiwan = {
					backend = 'openwrt',
					source = 'mwan3',
					interfaces_by_semantic = {
						modem_primary = {
							interface = 'modem_primary',
							ifname = 'wwan0',
							state = 'online',
							usable = true,
						},
					},
				},
				live = { interfaces = { wwan0 = { ipv4 = { { address = '10.1.2.3' } } } } },
			},
		},
	}, { now = 42 })

	local uplink = ok(model.uplinks.gsm_primary, 'gsm uplink expected')
	eq(uplink.state, 'online')
	eq(uplink.usable, true)
	eq(uplink.observed, true)
	eq(uplink.source.kind, 'gsm-uplink')
	eq(uplink.source.id, 'primary')
	eq(uplink.status_source.kind, 'host-multiwan')
	eq(uplink.status_source.tool, 'mwan3')
	eq(uplink.link.kind, 'cellular')
	eq(uplink.ifname, 'wwan0')
	eq(uplink.path_address.address, '10.1.2.3')
	eq(uplink.gsm, nil)
end

function tests.test_gsm_uplink_remains_offline_when_mwan3_is_offline_even_if_gsm_connected()
	local model = backhaul.reduce({
		wan = {
			configured_members = {
				gsm_primary = { interface = 'modem_primary', source = { kind = 'gsm-uplink', id = 'primary' } },
			},
		},
		sources = {
			gsm_uplinks = {
				primary = {
					state = 'connected',
					connected = true,
					linux = { ifname = 'wwan0' },
				},
			},
		},
		observed = {
			snapshot = {
				multiwan = {
					backend = 'openwrt',
					source = 'mwan3',
					interfaces_by_semantic = {
						modem_primary = {
							interface = 'modem_primary',
							ifname = 'wwan0',
							state = 'offline',
							usable = false,
						},
					},
				},
			},
		},
	}, { now = 42 })

	local uplink = ok(model.uplinks.gsm_primary, 'gsm uplink expected')
	eq(uplink.state, 'offline')
	eq(uplink.usable, false)
	eq(uplink.ifname, 'wwan0')
end

function tests.test_gsm_member_stays_present_without_gsm_details()
	local model = backhaul.reduce({
		wan = {
			configured_members = {
				gsm_primary = { interface = 'modem_primary', source = { kind = 'gsm-uplink', id = 'primary' } },
			},
		},
		observed = {
			snapshot = {
				multiwan = {
					backend = 'openwrt',
					source = 'mwan3',
					interfaces_by_semantic = {
						modem_primary = {
							interface = 'modem_primary',
							ifname = 'wwan0',
							state = 'offline',
							usable = false,
						},
					},
				},
			},
		},
	}, { now = 42 })

	local uplink = ok(model.uplinks.gsm_primary, 'gsm uplink expected')
	eq(uplink.state, 'offline')
	eq(uplink.usable, false)
	eq(uplink.source.id, 'primary')
	eq(uplink.ifname, 'wwan0')
end

function tests.test_live_addresses_reach_members_with_shortened_openwrt_names()
	local function snap(address)
		return {
			wan = { configured_members = {
				modem_primary = { interface = 'modem_primary', metric = 2, source = { kind = 'gsm-uplink', id = 'primary' } },
				lte_backup = { interface = 'lte_backup', metric = 3 },
			} },
			sources = { gsm_uplinks = { primary = { connected = true, linux = { ifname = 'wwan0' } } } },
			observed = { snapshot = {
				multiwan = { interfaces_by_semantic = {
					modem_primary = { interface = 'mopri79e', state = 'online', usable = true },
					lte_backup = { interface = 'ltbac1a2', state = 'online', usable = true },
				} },
				live = {
					-- HAL keys live records by the generated OpenWrt name and
					-- indexes them by product interface.
					interfaces = {
						mopri79e = { ipv4 = { { address = address } } },
						ltbac1a2 = { ipv4 = { { address = '192.0.2.5' } } },
					},
					interfaces_by_semantic = {
						modem_primary = { ipv4 = { { address = address } } },
						lte_backup = { ipv4 = { { address = '192.0.2.5' } } },
					},
				},
			} },
		}
	end
	local model = backhaul.reduce(snap('10.1.2.3'), { now = 1 })
	eq(model.uplinks.modem_primary.path_address.address, '10.1.2.3', 'gsm member')
	eq(model.uplinks.modem_primary.path_address.source, 'hal-network-live')
	eq(model.uplinks.lte_backup.path_address.address, '192.0.2.5', 'host member')

	-- The address feeds the speedtest measurement key, so a new address re-tests.
	local policy = require 'services.net.wan_policy'
	local function due_after_change()
		local before = snap('10.1.2.3')
		before.backhaul = backhaul.reduce(before, { now = 1 })
		before.wan.load_balancing = { speedtests = { enabled = true, interval_s = 1000 } }
		local uplink
		for _, u in ipairs(policy.collect_uplinks(before)) do if u.uplink_id == 'modem_primary' then uplink = u end end
		local m = policy.measurement(before, uplink)
		local after = snap('10.9.8.7')
		after.backhaul = backhaul.reduce(after, { now = 2 })
		after.wan.load_balancing = before.wan.load_balancing
		after.wan_runtime = { speedtests = { modem_primary = {
			state = 'ok', ok = true, last_success_mbps = 20, measurement_key = m.key,
			last_success = { mbps = 20, completed_at = 10, measurement_key = m.key, measurement = m },
		} } }
		for _, u in ipairs(policy.collect_uplinks(after)) do if u.uplink_id == 'modem_primary' then uplink = u end end
		return policy.speedtest_due(after, uplink, { generation = 1, now = 20 })
	end
	local due, reason = due_after_change()
	eq(due, true)
	eq(reason, 'path_changed_ip')
end

return tests
