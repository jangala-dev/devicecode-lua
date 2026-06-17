local fibers = require 'fibers'
local busmod = require 'bus'

local runfibers = require 'tests.support.run_fibers'
local probe = require 'tests.support.bus_probe'

local wired_service = require 'services.wired.service'
local wired_config = require 'services.wired.config'
local wired_topics = require 'services.wired.topics'

local T = {}

local function assert_eq(a, b, msg)
	if a ~= b then error(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)), 2) end
end

local function assert_not_nil(v, msg)
	if v == nil then error(msg or 'expected non-nil', 2) end
	return v
end

local function retain_net_segments(conn)
	conn:retain({ 'state', 'net', 'segments' }, {
		rev = 1,
		segments = {
			adm = { kind = 'system', protected = true, vlan = { id = 8 } },
			int = { kind = 'system', protected = true, vlan = { id = 100 } },
			jan = { kind = 'user', vlan = { id = 32 } },
			wan = { kind = 'wan', vlan = { id = 4 } },
		},
	})
end

local function retain_device_assembly(conn)
	conn:retain({ 'state', 'device', 'assembly' }, {
		kind = 'device.assembly',
		product = 'big-box',
		components = {
			cm5 = { kind = 'compute', role = 'controller' },
			mcu = { kind = 'microcontroller', role = 'power-sensor-controller' },
			['cm5-local-wired'] = { kind = 'direct-nic', role = 'controller-wired-port' },
			['switch-main'] = { kind = 'switch', role = 'wired-fabric' },
		},
		links = {
			['cm5-switch'] = {
				kind = 'wired',
				role = 'controller-switch-uplink',
				internal = true,
				a = { component = 'cm5-local-wired', observed_surface = 'eth0' },
				b = { component = 'switch-main', observed_surface = 'GE8' },
			},
		},
		surfaces = {
			['cm5-eth0'] = { component = 'cm5-local-wired', observed_surface = 'eth0', exposure = 'internal' },
			['switch-uplink-cm5'] = { component = 'switch-main', observed_surface = 'GE8', exposure = 'internal' },
			['lan-1'] = { component = 'switch-main', observed_surface = 'GE1', exposure = 'external' },
		},
	})
end

local function retain_raw_wired_observations(conn)
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'cm5-local-wired', 'status' }, {
		state = 'available',
		available = true,
	})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'cm5-local-wired', 'state', 'surfaces' }, {
		surfaces = {
			eth0 = {
				observed_surface = 'eth0',
				kind = 'direct-nic',
				capabilities = { trunk = true, access = false, poe = false },
				link = { state = 'up', speed_mbps = 1000 },
				attachment = { mode = 'trunk', vlans = { 8, 100, 32, 4 } },
			},
		},
	})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'status' }, {
		state = 'available',
		available = true,
		mode = 'read_only',
		driver = 'rtl8380m_http',
	})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'runtime' }, {
		cpu = { utilisation_pct = 3 },
		memory = { utilisation_pct = 61 },
	})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'power' }, {
		poe = { total_power_mw = 0, total_power_w = 0, temperature_c = 28 },
	})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'surfaces' }, {
		surfaces = {
			GE8 = {
				observed_surface = 'GE8',
				kind = 'switch-port',
				capabilities = { trunk = true, access = false, poe = false },
				link = { state = 'up', speed_mbps = 1000 },
				attachment = { mode = 'trunk', vlans = { 8, 100, 32, 4 } },
			},
			GE1 = {
				observed_surface = 'GE1',
				kind = 'ethernet-port',
				capabilities = { access = true, trunk = true, poe = true },
				link = { state = 'up', speed_mbps = 1000 },
				attachment = { mode = 'access', vlan = 32 },
				poe = { state = 'off' },
				counters = { rx = { bytes = 1234, packets = 12, drops = 0, errors = 0 } },
			},
		},
	})
end

local function retain_wired_config(conn)
	conn:retain({ 'cfg', 'wired' }, {
		rev = 1,
		data = {
			schema = wired_config.SCHEMA,
			version = 1,
			surfaces = {
				['switch-uplink-cm5'] = {
					kind = 'switch-port',
					role = 'internal-trunk',
					protected = true,
					attachment = { mode = 'trunk', required_segments = { 'adm', 'int' }, user_segments = 'all-realised-user-segments' },
				},
				['lan-1'] = {
					kind = 'ethernet-port',
					role = 'access',
					capabilities = { poe = true },
					attachment = { mode = 'access', segment = 'jan' },
				},
			},
		},
	})
end

function T.state_device_assembly_and_raw_switch_observations_project_to_state_wired()
	runfibers.run(function (scope)
		local b = busmod.new()
		local service_conn = b:connect({ origin_base = { kind = 'local', component = 'wired-service-test' } })
		local writer = b:connect({ origin_base = { kind = 'local', component = 'wired-test-writer' } })
		local reader = b:connect({ origin_base = { kind = 'local', component = 'wired-test-reader' } })

		retain_net_segments(writer)
		retain_device_assembly(writer)
		retain_raw_wired_observations(writer)
		retain_wired_config(writer)

		local child = assert(scope:child())
		assert(child:spawn(function (svc_scope) wired_service.run(svc_scope, { conn = service_conn, service_id = 'test-wired' }) end))

		local lan1 = probe.wait_retained_payload(reader, wired_topics.surface('lan-1'), { timeout = 1.5 })
		assert_eq(lan1.surface_id, 'lan-1')
		assert_eq(lan1.attachment.mode, 'access')
		assert_eq(lan1.attachment.segment, 'jan')
		assert_eq(lan1.availability.state, 'available')
		assert_eq(lan1.link.state, 'up')
		assert_eq(lan1.source.component, 'switch-main')
		assert_eq(lan1.source.observed_surface, 'GE1')
		assert_eq(lan1.observed.source.exposure, 'external')
		assert_eq(lan1.counters.rx.bytes, 1234)

		local uplink = probe.wait_retained_payload(reader, wired_topics.surface('switch-uplink-cm5'), { timeout = 1.5 })
		assert_eq(uplink.availability.state, 'available')
		assert_eq(uplink.source.component, 'switch-main')
		assert_eq(uplink.source.observed_surface, 'GE8')
		assert_eq(uplink.observed.source.exposure, 'internal')

		local topology = probe.wait_retained_payload(reader, wired_topics.topology(), { timeout = 1.0 })
		assert_not_nil(topology.protected_trunks['switch-uplink-cm5'])
		local violations = probe.wait_retained_payload(reader, wired_topics.violations(), { timeout = 1.0 })
		assert_eq(#(violations.violations or {}), 0)

		child:cancel('test complete')
		fibers.perform(child:join_op())
	end, { timeout = 3.0 })
end

return T
