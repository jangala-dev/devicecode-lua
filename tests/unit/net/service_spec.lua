-- tests/net_service_spec.lua

local busmod       = require 'bus'

local runfibers    = require 'tests.support.run_fibers'
local probe        = require 'tests.support.bus_probe'
local fake_hal_mod = require 'tests.support.fake_hal'

local net_service  = require 'services.net'

local T = {}

local function net_timings()
	return {
		hal_wait_timeout_s = 0.25,
		hal_wait_tick_s    = 0.01,
	}
end

local function valid_net_config()
	return {
		network = {
			nets = {
				wan = {
					ipv4 = { proto = 'dhcp' },
					multiwan = {
						metric = 1,
						weight = 2,
					},
				},
			},
		},
		multiwan = {
			globals = { enabled = true },
			health = {
				track_method = 'ping',
				track_ip     = { '1.1.1.1' },
				interval_s   = 0.05,
				timeout_s    = 1.0,
				up           = 1,
				down         = 1,
			},
		},
		runtime = {
			net = {
				structural_debounce_s = 0.01,
				inventory_refresh_s   = 0.10,
				probe_interval_s      = 0.05,
				counter_interval_s    = 0.05,
				control_interval_s    = 0.05,
				persist_quiet_s       = 0.10,
			},
		},
	}
end

local function invalid_net_config()
	return {
		network = {
			nets = {
				wan = {
					ipv4 = {
						proto      = 'static',
						ip_address = '192.0.2.10',
						netmask    = 'badmask',
					},
				},
			},
		},
	}
end

local function collect_method_calls(fake_hal, method)
		local out = {}
		for i = 1, #fake_hal.calls do
			local c = fake_hal.calls[i]
			if c.method == method then
				out[#out + 1] = c
			end
		end
		return out
end

function T.net_applies_initial_bundle_and_skips_failed_revision()
	runfibers.run(function(scope)
		local bus  = busmod.new()
		local conn = bus:connect()

		local fake_hal = fake_hal_mod.new({
			backend = 'fakehal',
			caps = {
				apply_net               = true,
				list_links              = true,
				probe_links             = true,
				read_link_counters      = true,
				apply_link_shaping_live = true,
				apply_multipath_live    = true,
				persist_multipath_state = true,
			},
			scripted = {
				apply_net = {
					function(req)
						return { ok = true, applied = true, changed = true, rev = req.rev, gen = req.gen }
					end,
					function(req)
						return { ok = true, applied = true, changed = true, rev = req.rev, gen = req.gen }
					end,
				},
				list_links = {
					{ ok = true, links = { wan = { ok = true, device = 'eth0', resolved = true } } },
					{ ok = true, links = { wan = { ok = true, device = 'eth0', resolved = true } } },
				},
				probe_links = {
					{ ok = true, samples = { wan = { ok = true, device = 'eth0', reflector = '1.1.1.1', rtt_ms = 12 } } },
					{ ok = true, samples = { wan = { ok = true, device = 'eth0', reflector = '1.1.1.1', rtt_ms = 10 } } },
				},
				read_link_counters = {
					{ ok = true, links = { wan = { ok = true, device = 'eth0', rx_bytes = 1000, tx_bytes = 2000, rx_packets = 10, tx_packets = 20 } } },
					{ ok = true, links = { wan = { ok = true, device = 'eth0', rx_bytes = 2000, tx_bytes = 4000, rx_packets = 20, tx_packets = 40 } } },
				},
				apply_link_shaping_live = {
					{ ok = true, applied = true, changed = false },
					{ ok = true, applied = true, changed = false },
				},
				apply_multipath_live = {
					{ ok = true, applied = true, changed = false },
					{ ok = true, applied = true, changed = false },
				},
				persist_multipath_state = {
					{ ok = true, applied = true, changed = true },
				},
			},
		})

		fake_hal:start(bus:connect(), { name = 'hal' })

		local ok_spawn, err = scope:spawn(function()
			net_service.start(bus:connect(), {
				name    = 'net',
				env     = 'dev',
				timings = net_timings(),
			})
		end)
		assert(ok_spawn, tostring(err))

		conn:retain({ 'config', 'net' }, {
			rev  = 5,
			data = valid_net_config(),
		})

		local got_first_apply = probe.wait_until(function()
			local calls = collect_method_calls(fake_hal, 'apply_net')
			return #calls >= 1
		end, { timeout = 0.5, interval = 0.005 })

		assert(got_first_apply == true, 'expected first apply_net call')

		local apply_calls = collect_method_calls(fake_hal, 'apply_net')
		assert(apply_calls[1].req.rev == 5)

		conn:retain({ 'config', 'net' }, {
			rev  = 6,
			data = invalid_net_config(),
		})

		-- Give the service a moment to reject the bad compile.
		probe.wait_until(function() return false end, { timeout = 0.05, interval = 0.01 })

		apply_calls = collect_method_calls(fake_hal, 'apply_net')
		assert(#apply_calls == 1, 'bad config should not trigger apply_net')

		conn:retain({ 'config', 'net' }, {
			rev  = 7,
			data = valid_net_config(),
		})

		local got_second_apply = probe.wait_until(function()
			local calls = collect_method_calls(fake_hal, 'apply_net')
			return #calls >= 2
		end, { timeout = 0.5, interval = 0.005 })

		assert(got_second_apply == true, 'expected second apply_net call')

		apply_calls = collect_method_calls(fake_hal, 'apply_net')
		assert(apply_calls[2].req.rev == 7, 'service should skip failed rev 6 and apply rev 7')
	end, { timeout = 1.5 })
end

return T
