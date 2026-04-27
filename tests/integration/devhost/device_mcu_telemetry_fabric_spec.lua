local busmod    = require 'bus'
local duplex    = require 'tests.support.duplex_stream'
local probe     = require 'tests.support.bus_probe'
local runfibers = require 'tests.support.run_fibers'
local mailbox   = require 'fibers.mailbox'
local fibers    = require 'fibers'

local session = require 'services.fabric.session'
local device  = require 'services.device'

local T = {}

local function make_svc(conn)
	return {
		conn = conn,
		now = function() return require('fibers').now() end,
		wall = function() return 'now' end,
		obs_log = function() end,
		obs_event = function() end,
		obs_state = function() end,
		status = function() end,
	}
end

local function wait_ready(conn, link_id, timeout)
	probe.wait_fabric_link_session(conn, link_id, function(payload)
		return type(payload.status) == 'table' and payload.status.ready == true
	end, { timeout = timeout or 1.5 })
	return true
end

local function wait_service_running(conn, name, timeout)
	probe.wait_service_running(conn, name, { timeout = timeout or 1.5 })
	return true
end

local function wait_device_component(conn, name, pred, timeout)
	probe.wait_device_component(conn, name, pred, { timeout = timeout or 1.5 })
	return true
end

local function seed_device_cfg(conn)
	conn:retain({ 'cfg', 'device' }, {
		schema = 'devicecode.config/device/1',
		components = {
			mcu = {
				class = 'member',
				subtype = 'mcu',
				member_class = 'mcu',
				link_class = 'member_uart',
				facts = {
					software = { 'raw', 'member', 'mcu', 'state', 'software' },
					updater = { 'raw', 'member', 'mcu', 'state', 'updater' },
					health = { 'raw', 'member', 'mcu', 'state', 'health' },
					power_battery = { 'raw', 'member', 'mcu', 'state', 'power', 'battery' },
					power_charger = { 'raw', 'member', 'mcu', 'state', 'power', 'charger' },
					power_charger_config = { 'raw', 'member', 'mcu', 'state', 'power', 'charger', 'config' },
					environment_temperature = { 'raw', 'member', 'mcu', 'state', 'environment', 'temperature' },
					environment_humidity = { 'raw', 'member', 'mcu', 'state', 'environment', 'humidity' },
					runtime_memory = { 'raw', 'member', 'mcu', 'state', 'runtime', 'memory' },
				},
				events = {
					charger_alert = { 'raw', 'member', 'mcu', 'cap', 'telemetry', 'main', 'event', 'power', 'charger', 'alert' },
				},
				actions = {
					['prepare-update'] = { 'rpc', 'member', 'mcu', 'prepare' },
					['commit-update'] = { 'rpc', 'member', 'mcu', 'commit' },
				},
			},
		},
	})
end

local function publish_remote_mcu_state(conn)
	conn:retain({ 'state', 'self', 'software' }, {
		version = 'mcu-v1',
		build = 'abc123',
		image_id = 'mcu-fw-v1',
		boot_id = 'boot-1',
	})
	conn:retain({ 'state', 'self', 'updater' }, {
		state = 'running',
		last_error = nil,
		pending_version = nil,
	})
	conn:retain({ 'state', 'self', 'health' }, {
		state = 'ok',
	})
	conn:retain({ 'state', 'self', 'power', 'battery' }, {
		pack_mV = 24120,
		per_cell_mV = 12060,
		ibat_mA = -420,
		temp_mC = 19800,
		bsr_uohm_per_cell = 1800,
		seq = 11,
		uptime_ms = 1234,
	})
	conn:retain({ 'state', 'self', 'power', 'charger' }, {
		vin_mV = 24317,
		vsys_mV = 24233,
		iin_mA = 658,
		state_bits = 2,
		status_bits = 4,
		system_bits = 870,
		state = {
			bat_missing_fault = true,
			bat_short_fault = false,
			max_charge_time_fault = false,
		},
		status = {
			iin_limit_active = true,
			vin_uvcl_active = false,
		},
		system = {
			charger_enabled = true,
			ok_to_charge = true,
			thermal_shutdown = false,
		},
		seq = 12,
		uptime_ms = 1240,
	})
	conn:retain({ 'state', 'self', 'power', 'charger', 'config' }, {
		schema = 1,
		source = 'ltc4015',
		thresholds = {
			vin_lo_mV = 9000,
			vin_hi_mV = 32000,
			bsr_high_uohm_per_cell = 50000,
		},
		alert_mask_bits = 16383,
		alert_mask = {
			vin_lo = true,
			vin_hi = true,
			bsr_high = true,
			bat_missing = true,
			bat_short = true,
			max_charge_time_fault = true,
			absorb = true,
			equalize = true,
			cccv = true,
			precharge = true,
			iin_limited = true,
			uvcl_active = true,
			cc_phase = true,
			cv_phase = true,
		},
		seq = 2,
		uptime_ms = 1250,
	})
	conn:retain({ 'state', 'self', 'environment', 'temperature' }, {
		deci_c = 191,
		seq = 13,
		uptime_ms = 1260,
	})
	conn:retain({ 'state', 'self', 'environment', 'humidity' }, {
		rh_x100 = 4690,
		seq = 14,
		uptime_ms = 1270,
	})
	conn:retain({ 'state', 'self', 'runtime', 'memory' }, {
		alloc_bytes = 85680,
		seq = 15,
		uptime_ms = 1280,
	})
end

local function start_fabric_pair(scope, bus, a_stream, b_stream)
	local a_ctl_tx, a_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
	local b_ctl_tx, b_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
	local a_report_tx, a_report_rx = mailbox.new(8, { full = 'reject_newest' })
	local b_report_tx, b_report_rx = mailbox.new(8, { full = 'reject_newest' })

	local ok1, err1 = scope:spawn(function()
		session.run({
			svc = make_svc(bus:connect()),
			conn = bus:connect(),
			link_id = 'cm5-uart-mcu',
			transfer_ctl_rx = a_ctl_rx,
			report_tx = a_report_tx,
			cfg = {
				node_id = 'cm5',
				member_class = 'cm5',
				link_class = 'member_uart',
				transport = { open = function() return a_stream end },
				import_rules = {
					{ ['local'] = { 'raw', 'member', 'mcu', 'state' }, ['remote'] = { 'state', 'self' } },
					{ ['local'] = { 'raw', 'member', 'mcu', 'cap', 'telemetry', 'main', 'event' }, ['remote'] = { 'event', 'self' } },
				},
				outbound_call_rules = {
					{ ['local'] = { 'rpc', 'member', 'mcu' }, ['remote'] = { 'rpc', 'member', 'mcu' }, timeout = 1.0 },
				},
			},
		})
	end)
	assert(ok1, tostring(err1))

	local ok2, err2 = scope:spawn(function()
		session.run({
			svc = make_svc(bus:connect()),
			conn = bus:connect(),
			link_id = 'mcu-uart-cm5',
			transfer_ctl_rx = b_ctl_rx,
			report_tx = b_report_tx,
			cfg = {
				node_id = 'mcu',
				member_class = 'mcu',
				link_class = 'member_uart',
				transport = { open = function() return b_stream end },
				export_retained_rules = {
					{ ['local'] = { 'state', 'self' }, ['remote'] = { 'state', 'self' } },
				},
				export_publish_rules = {
					{ ['local'] = { 'event', 'self' }, ['remote'] = { 'event', 'self' } },
				},
				inbound_call_rules = {
					{ ['local'] = { 'rpc', 'member', 'mcu' }, ['remote'] = { 'rpc', 'member', 'mcu' }, timeout = 1.0 },
				},
			},
		})
	end)
	assert(ok2, tostring(err2))
end

function T.devhost_mcu_rich_telemetry_flows_over_fabric_into_device_component()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local caller = bus:connect()
		local seed = bus:connect()

		seed_device_cfg(seed)

		local a_stream, b_stream = duplex.new_pair()
		start_fabric_pair(scope, bus, a_stream, b_stream)

		local ok, err = scope:spawn(function()
			device.start(bus:connect(), { name = 'device', env = 'dev' })
		end)
		assert(ok, tostring(err))

		assert(wait_ready(caller, 'cm5-uart-mcu', 2.0) == true)
		assert(wait_ready(caller, 'mcu-uart-cm5', 2.0) == true)
		assert(wait_service_running(caller, 'device', 1.5) == true)

		local remote_member_conn = bus:connect()
		publish_remote_mcu_state(remote_member_conn)

		assert(wait_device_component(caller, 'mcu', function(payload)
			return payload.available == true
				and payload.ready == true
				and payload.software.version == 'mcu-v1'
				and payload.power.battery.pack_mV == 24120
				and payload.power.charger.vin_mV == 24317
				and payload.power.charger.status.iin_limit_active == true
				and payload.power.charger_config.thresholds.vin_lo_mV == 9000
				and payload.environment.temperature.deci_c == 191
				and payload.environment.humidity.rh_x100 == 4690
				and payload.runtime.memory.alloc_bytes == 85680
		end, 2.0))
	end, { timeout = 4.0 })
end

function T.devhost_mcu_charger_alert_event_flows_over_fabric_and_updates_last_alert_summary()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local caller = bus:connect()
		local seed = bus:connect()

		seed_device_cfg(seed)

		local a_stream, b_stream = duplex.new_pair()
		start_fabric_pair(scope, bus, a_stream, b_stream)

		local ok, err = scope:spawn(function()
			device.start(bus:connect(), { name = 'device', env = 'dev' })
		end)
		assert(ok, tostring(err))

		assert(wait_ready(caller, 'cm5-uart-mcu', 2.0) == true)
		assert(wait_ready(caller, 'mcu-uart-cm5', 2.0) == true)
		assert(wait_service_running(caller, 'device', 1.5) == true)

		local remote_member_conn = bus:connect()
		publish_remote_mcu_state(remote_member_conn)
		assert(wait_device_component(caller, 'mcu', function(payload)
			return payload.available == true and payload.ready == true
		end, 2.0))

		local event_sub = caller:subscribe(
			{ 'raw', 'member', 'mcu', 'cap', 'telemetry', 'main', 'event', 'power', 'charger', 'alert' },
			{
				queue_len = 8,
				full = 'drop_oldest',
			}
		)
		fibers.current_scope():finally(function()
			event_sub:unsubscribe()
		end)

		local alert = {
			kind = 'vin_lo',
			severity = 'warn',
			source = 'ltc4015',
			state_bits = 2,
			status_bits = 4,
			system_bits = 870,
			seq = 99,
			uptime_ms = 2222,
		}
		remote_member_conn:publish({ 'event', 'self', 'power', 'charger', 'alert' }, alert)

		local msg = event_sub:recv()
		assert(type(msg) == 'table')
		assert(type(msg.payload) == 'table')
		assert(msg.payload.kind == 'vin_lo')
		assert(msg.payload.source == 'ltc4015')

		assert(wait_device_component(caller, 'mcu', function(payload)
			return type(payload.alerts) == 'table'
				and type(payload.alerts.charger_alert) == 'table'
				and payload.alerts.charger_alert.kind == 'vin_lo'
				and payload.alerts.charger_alert.known == true
				and payload.alerts.charger_alert.uptime_ms == 2222
		end, 1.5))
	end, { timeout = 4.0 })
end

return T
