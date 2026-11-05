-- tests/unit/hal/radio_driver_spec.lua

local tests = {}

local function eq(a, b, msg)
	if a ~= b then
		error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
	end
end

function tests.test_set_channels_htmodes_match_openwrt()
	local cap_args = require 'services.hal.types.capability_args'
	local radio = require 'services.hal.drivers.radio'

	-- Accepted as given: the forms OpenWrt's mac80211.sh understands.
	for _, mode in ipairs({ 'HE20', 'HE40', 'HE80', 'HE160', 'HT20', 'HT40+', 'HT40-',
		'VHT20', 'VHT40', 'VHT80', 'VHT160' }) do
		local opts, err = cap_args.new.RadioSetChannelsOpts('5g', 36, mode)
		eq(err, '', mode .. ' should be accepted')
		eq(opts.htmode, mode)
	end

	-- HE40±/VHT40± would silently run at 20 MHz; they map to HE40/VHT40.
	local mapped = { ['HE40+'] = 'HE40', ['HE40-'] = 'HE40', ['VHT40+'] = 'VHT40', ['VHT40-'] = 'VHT40' }
	for given, want in pairs(mapped) do
		local opts, err = cap_args.new.RadioSetChannelsOpts('5g', 36, given)
		eq(err, '', given .. ' should be accepted')
		eq(opts.htmode, want, given .. ' should map')
	end

	for _, mode in ipairs({ 'HT40', 'HE40x', 'EHT40', '' }) do
		local opts = cap_args.new.RadioSetChannelsOpts('5g', 36, mode)
		eq(opts, nil, mode .. ' should be rejected')
	end

	-- The driver stages the mapped value, also for a plain request table.
	local driver = setmetatable({ id = 'radio1', staged = {} }, radio.Driver)
	local ok, reason = driver:set_channels({ band = '5g', channel = 100, htmode = 'HE40+' })
	eq(ok, true, tostring(reason))
	eq(driver.staged.htmode, 'HE40')
end

function tests.test_stats_loop_stops_when_client_monitor_cannot_start()
	local channel = require 'fibers.channel'
	local runfibers = require 'tests.support.run_fibers'
	local radio = require 'services.hal.drivers.radio'

	runfibers.run(function ()
		local start_calls = 0
		local watch_calls = 0
		local errors = {}

		local backend = {
			start_client_monitor = function ()
				start_calls = start_calls + 1
				return false, 'failed to start iw event: iw not found'
			end,

			watch_clients_op = function ()
				watch_calls = watch_calls + 1
				error('watch_clients_op should not be called after monitor startup failure', 2)
			end,
		}

		local driver = setmetatable({
			id = 'radio0',
			cap_emit_ch = channel.new(4),
			iface_update_ch = channel.new(4),
			report_period_ch = channel.new(1),
			backend = backend,
			log = {
				error = function (_, row)
					errors[#errors + 1] = row
				end,
				debug = function () end,
			},
		}, radio.Driver)

		driver:stats_loop()

		eq(start_calls, 1, 'client monitor should only be started once')
		eq(watch_calls, 0, 'stats loop should not watch clients after monitor startup failure')
		eq(#errors, 1, 'startup failure should be logged once')
		eq(errors[1].what, 'radio_stats_loop_failed', 'failure log event')
		eq(errors[1].id, 'radio0', 'failure log id')
	end, { timeout = 0.1 })
end

function tests.test_stats_loop_stops_when_client_monitor_stream_closes()
	local channel = require 'fibers.channel'
	local op = require 'fibers.op'
	local runfibers = require 'tests.support.run_fibers'
	local radio = require 'services.hal.drivers.radio'

	runfibers.run(function ()
		local start_calls = 0
		local watch_calls = 0
		local stop_calls = 0
		local errors = {}

		local backend = {
			start_client_monitor = function ()
				start_calls = start_calls + 1
				return true, ''
			end,

			watch_clients_op = function ()
				watch_calls = watch_calls + 1
				return op.always(nil, 'iw event stream closed')
			end,

			stop_client_monitor_op = function ()
				stop_calls = stop_calls + 1
				return op.always(true, '')
			end,

			terminate = function () return true, nil end,
		}

		local driver = setmetatable({
			id = 'radio0',
			cap_emit_ch = channel.new(4),
			iface_update_ch = channel.new(4),
			report_period_ch = channel.new(1),
			backend = backend,
			log = {
				error = function (_, row)
					errors[#errors + 1] = row
				end,
				debug = function () end,
			},
		}, radio.Driver)

		driver:stats_loop()

		eq(start_calls, 1, 'client monitor should only be started once')
		eq(watch_calls, 1, 'closed monitor stream should only be watched once')
		eq(stop_calls, 1, 'started monitor should be stopped after stream failure')
		eq(#errors, 1, 'stream failure should be logged once')
		eq(errors[1].what, 'radio_stats_loop_failed', 'failure log event')
		eq(errors[1].err, 'iw event stream closed', 'failure log err')
	end, { timeout = 0.1 })
end

-- Runs the stats loop against a fake backend. Returns the harness; the loop
-- lives in a child scope that the caller cancels.
local function start_stats_loop(scope, backend_overrides)
	local channel = require 'fibers.channel'
	local radio = require 'services.hal.drivers.radio'

	local h = { emits = {}, stations = {}, leases = {}, events = channel.new(64), counts = { tick = 0 } }
	local backend = {
		SYSFS_STATS = {},
		start_client_monitor = function () return true, '' end,
		watch_clients_op = function () return h.events:get_op() end,
		stop_client_monitor_op = function () local op = require 'fibers.op'; return op.always(true, '') end,
		terminate = function () return true, nil end,
		get_connected_macs = function (_, iface) return h.stations[iface] or {}, '' end,
		get_iface_info = function () h.counts.tick = h.counts.tick + 1; return nil end,
		get_iface_survey = function () return nil end,
		get_station_info = function () return nil end,
		read_sysfs_stat = function () return nil end,
		get_dhcp_hostnames = function () return h.leases, '' end,
	}
	for k, v in pairs(backend_overrides or {}) do backend[k] = v end

	local emit_ch = channel.new(256)
	h.driver = setmetatable({
		id = 'radio0',
		cap_emit_ch = emit_ch,
		iface_update_ch = channel.new(8),
		report_period_ch = channel.new(1),
		backend = backend,
		log = { error = function () end, debug = function () end },
	}, radio.Driver)

	h.scope = assert(scope:child())
	h.scope:spawn(function () h.driver:stats_loop() end)
	h.scope:spawn(function ()
		while true do h.emits[#h.emits + 1] = emit_ch:get() end
	end)
	return h
end

local function emitted(h, mode, key)
	local out = {}
	for _, e in ipairs(h.emits) do
		if e.mode == mode and e.key == key then out[#out + 1] = e.data end
	end
	return out
end

function tests.test_stats_loop_tracks_clients_once_and_retains_the_set()
	local runfibers = require 'tests.support.run_fibers'
	local sleep = require 'fibers.sleep'

	runfibers.run(function (scope)
		local h = start_stats_loop(scope)
		h.stations.radio0_i0 = { 'aa' }
		h.driver.iface_update_ch:put({ op = 'add', name = 'radio0_i0' })
		-- Let the interface register first: the loop picks among ready inputs at
		-- random and ignores events for interfaces it does not track yet.
		sleep.sleep(0.005)
		h.events:put({ mac = 'aa', interface = 'radio0_i0', added = true }) -- duplicate of the seed
		h.events:put({ mac = 'bb', interface = 'radio0_i0', added = true })
		sleep.sleep(0.01)

		local events = emitted(h, 'event', 'client_event')
		eq(#events, 2, 'one connect each for aa and bb, duplicate dropped')
		local clients = emitted(h, 'state', 'clients')
		eq(#clients[#clients].interfaces.radio0_i0, 2, 'retained set has aa and bb')

		-- aa leaves without an event; bb's DHCP lease appears. The tick reconciles both.
		h.stations.radio0_i0 = { 'bb' }
		h.leases = { bb = 'laptop' }
		h.driver.report_period_ch:put(0.02)
		sleep.sleep(0.05)

		events = emitted(h, 'event', 'client_event')
		eq(events[3].mac, 'aa')
		eq(events[3].connected, false, 'missed disconnect found on tick')
		clients = emitted(h, 'state', 'clients')
		local last = clients[#clients]
		eq(#last.interfaces.radio0_i0, 1)
		eq(last.interfaces.radio0_i0[1], 'bb')
		eq(last.hostnames.bb, 'laptop')
		eq(last.hostnames.aa, nil)

		h.scope:cancel('test done')
	end, { timeout = 1 })
end

function tests.test_stats_loop_keeps_reporting_under_client_churn()
	local runfibers = require 'tests.support.run_fibers'
	local sleep = require 'fibers.sleep'

	runfibers.run(function (scope)
		local h = start_stats_loop(scope)
		h.driver.iface_update_ch:put({ op = 'add', name = 'radio0_i0' })
		h.driver.report_period_ch:put(0.05)
		-- A client event every 20 ms used to restart a relative 50 ms timer forever.
		for i = 1, 15 do
			h.events:put({ mac = 'cc', interface = 'radio0_i0', added = (i % 2 == 1) })
			sleep.sleep(0.02)
		end
		assert(h.counts.tick >= 4, 'expected at least 4 reports in 300 ms, got ' .. h.counts.tick)
		h.scope:cancel('test done')
	end, { timeout = 1 })
end

function tests.test_stats_loop_passes_64bit_counters_through()
	local runfibers = require 'tests.support.run_fibers'
	local sleep = require 'fibers.sleep'

	runfibers.run(function (scope)
		local h = start_stats_loop(scope, {
			SYSFS_STATS = { 'rx_bytes' },
			read_sysfs_stat = function () return 5000000000, nil end,
			get_station_info = function ()
				return { signal = 4294967200, tx_bytes = 3000000000, rx_bytes = 2500000000 }, ''
			end,
		})
		h.stations.radio0_i0 = { 'aa' }
		h.driver.iface_update_ch:put({ op = 'add', name = 'radio0_i0' })
		h.driver.report_period_ch:put(0.02)
		sleep.sleep(0.05)

		eq(emitted(h, 'state', 'iface_rx_bytes')[1].value, 5000000000, 'interface bytes are 64-bit')
		eq(emitted(h, 'state', 'client_tx_bytes')[1].value, 3000000000, 'client tx bytes are 64-bit')
		eq(emitted(h, 'state', 'client_rx_bytes')[1].value, 2500000000, 'client rx bytes are 64-bit')
		eq(emitted(h, 'state', 'client_signal')[1].value, -96, 'signal is signed 32-bit')
		h.scope:cancel('test done')
	end, { timeout = 1 })
end

return tests
