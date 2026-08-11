local modem_driver = require 'services.hal.drivers.modem'
local cache = require 'shared.cache'
local pulse = require 'fibers.pulse'
local runfibers = require 'tests.support.run_fibers'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end end

function tests.test_signal_poller_only_runs_for_registered_connection_states()
	local active = modem_driver._test.signal_polling_active
	eq(active('disabled'), false)
	eq(active('locked'), false)
	eq(active('registered'), true)
	eq(active('connecting'), true)
	eq(active('connected'), true)
end

function tests.test_signal_poll_emits_access_tech_and_measurements_together()
	runfibers.run(function()
		local emitted
		local driver = setmetatable({
			backend = {
				read_access_techs = function()
					return { 'lte', '5gnr' }, ''
				end,
				read_signal = function()
					return {
						values = {
							lte = { rsrp = -96 },
							['5g'] = { rsrp = -103 },
						},
					}, ''
				end,
			},
			cache = cache.new(math.huge),
			field_observed_at = {},
			cap_emit_ch = {
				put = function(_, payload)
					emitted = payload
				end,
			},
			imei = 'test-imei',
		}, modem_driver._test.Modem)
		driver.cache:set('network', {
			access_techs = { 'gsm' },
			operator = 'Demo',
		})

		local poll_ok, err = driver:_poll_signal_once()
		ok(poll_ok, err)
		eq(emitted.mode, 'event')
		eq(emitted.key, 'signal')
		eq(emitted.data.schema, 'devicecode.hal.modem.signal/1')
		eq(emitted.data.access_techs[1], 'lte')
		eq(emitted.data.access_techs[2], '5gnr')
		eq(emitted.data.signal.lte.rsrp, -96)
		eq(emitted.data.signal['5g'].rsrp, -103)
		eq(driver.cache:get('network', math.huge).operator, 'Demo')
		eq(driver.cache:get('network', math.huge).access_techs[2], '5gnr')
	end)
end

function tests.test_signal_poll_emits_empty_success_to_clear_stale_signal()
	runfibers.run(function()
		local emitted
		local driver = setmetatable({
			backend = {
				read_access_techs = function()
					return { 'lte' }, ''
				end,
				read_signal = function()
					return { values = {} }, ''
				end,
			},
			cache = cache.new(math.huge),
			field_observed_at = {},
			cap_emit_ch = {
				put = function(_, payload)
					emitted = payload
				end,
			},
			imei = 'test-imei',
		}, modem_driver._test.Modem)

		local poll_ok, err = driver:_poll_signal_once()
		ok(poll_ok, err)
		eq(emitted.data.access_techs[1], 'lte')
		eq(next(emitted.data.signal), nil)
	end)
end

function tests.test_full_info_snapshot_marks_present_and_absent_fields_as_observed()
	runfibers.run(function(scope)
		local emitted
		local done = pulse.new()
		local done_version = done:version()
		local driver = setmetatable({
			backend = {
				read_identity = function()
					return { imei = 'test-imei', drivers = {}, model = 'Test modem' }, ''
				end,
				read_ports = function()
					return { device = '/sys/test', at_ports = {}, qmi_ports = {}, net_ports = { 'wwan0' } }, ''
				end,
				read_sim_info = function()
					return { sim = 'present', modem_state = 'registered' }, ''
				end,
				read_network_info = function()
					return { access_techs = { 'lte' }, operator = 'Demo' }, ''
				end,
				read_signal = function()
					return { values = { lte = { rsrp = -96 } } }, ''
				end,
				read_traffic = function()
					return { rx_bytes = 1, tx_bytes = 2 }, ''
				end,
			},
			cache = cache.new(math.huge),
			field_observed_at = {},
			info_generation = 0,
			state_pulse = pulse.new(),
			cap_emit_ch = {
				put = function(_, payload)
					if payload.mode == 'state' and payload.key == 'info' then
						emitted = payload.data
						done:signal()
					end
				end,
			},
			imei = 'test-imei',
			log = {
				debug = function() end,
				warn = function() end,
			},
		}, modem_driver._test.Modem)

		local spawned, spawn_err = scope:spawn(function()
			driver:emitter()
		end)
		ok(spawned, spawn_err)
		driver.state_pulse:signal()
		done:changed(done_version)

		eq(emitted.schema, 'devicecode.hal.modem.info/1')
		eq(emitted.generation, 1)
		eq(emitted.values.operator, 'Demo')
		eq(emitted.values.sim_lock, nil)
		ok(type(emitted.observed_at.operator) == 'number')
		ok(type(emitted.observed_at.sim_lock) == 'number')
	end)
end

function tests.test_refresh_info_wakes_the_full_snapshot_emitter()
	runfibers.run(function()
		local driver = setmetatable({
			state_pulse = pulse.new(),
		}, modem_driver._test.Modem)
		local before = driver.state_pulse:version()
		local refresh_ok, reason = driver:refresh_info()
		ok(refresh_ok, reason)
		eq(reason, 'refresh requested')
		ok(driver.state_pulse:version() > before)
	end)
end

return tests
