-- tests/integration/devhost/rtl8380m_switch_spec.lua
--
-- Opt-in devhost tests for the real RTL8380M PoE/VLAN switch provider.
--
-- These tests talk to a real switch and are skipped unless the operator
-- supplies explicit test credentials:
--
--   SWITCH_TEST_BASE_URL=http://192.168.1.1/ \
--   SWITCH_TEST_USERNAME=admin \
--   SWITCH_TEST_PASSWORD=admin \
--   TEST_FILTER=rtl8380m_real_switch \
--   lua tests/run.lua
--
-- The tests exercise the production provider through cap/http/main.  They do
-- not submit VLAN, PoE, save, reboot or other configuration writes.

local busmod = require 'bus'
local fibers = require 'fibers'

local runfibers = require 'tests.support.run_fibers'
local probe = require 'tests.support.bus_probe'

local http_service = require 'services.http.service'
local wired_service = require 'services.wired.service'
local wired_config  = require 'services.wired.config'
local wired_topics  = require 'services.wired.topics'
local provider_mod = require 'services.hal.backends.wired.providers.rtl8380m_http'
local hal_deps = require 'services.hal.dependencies'

local T = {}

local function skip(reason)
	return { skip = true, reason = reason }
end

local function assert_true(v, msg)
	if v ~= true then error(msg or ('expected true, got ' .. tostring(v)), 2) end
end

local function assert_eq(a, b, msg)
	if a ~= b then error(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)), 2) end
end

local function assert_not_nil(v, msg)
	if v == nil then error(msg or 'expected non-nil', 2) end
	return v
end

local function required_env()
	local base_url = os.getenv('SWITCH_TEST_BASE_URL')
	local username = os.getenv('SWITCH_TEST_USERNAME')
	local password = os.getenv('SWITCH_TEST_PASSWORD')
	local missing = {}
	if not base_url or base_url == '' then missing[#missing + 1] = 'SWITCH_TEST_BASE_URL' end
	if not username or username == '' then missing[#missing + 1] = 'SWITCH_TEST_USERNAME' end
	if not password or password == '' then missing[#missing + 1] = 'SWITCH_TEST_PASSWORD' end
	if #missing > 0 then
		return nil, 'set ' .. table.concat(missing, ', ') .. ' to run the real switch integration test'
	end
	return {
		base_url = base_url,
		username = username,
		password = password,
		timeout_s = tonumber(os.getenv('SWITCH_TEST_HTTP_TIMEOUT_S') or '8') or 8,
		run_timeout_s = tonumber(os.getenv('SWITCH_TEST_RUN_TIMEOUT_S') or '30') or 30,
		openssl_bin = os.getenv('SWITCH_TEST_OPENSSL') or os.getenv('SWITCH_OPENSSL') or 'openssl',
	}
end

local function wait_http_available(bus)
	local reader = bus:connect({ origin_base = { kind = 'local', component = 'test-http-reader' } })
	probe.wait_retained_payload(reader, { 'cap', 'http', 'main', 'status' }, {
		timeout = 2.0,
		view_topic = { 'cap', 'http', 'main', 'status' },
	})
	assert_true(probe.wait_until(function ()
		local view = reader:retained_view({ 'cap', 'http', 'main', 'status' })
		local msg = view:get({ 'cap', 'http', 'main', 'status' })
		view:close()
		local payload = msg and msg.payload or nil
		return payload and payload.available == true
	end, { timeout = 2.0, interval = 0.01 }), 'HTTP capability should become available')
end

local function start_http_capability(bus, opts)
	local conn = bus:connect({ origin_base = { kind = 'local', component = 'test-http-service' } })
	return assert(http_service.open_handle(conn, {
		id = 'main',
		backend_timeout = opts.timeout_s,
		connection_setup_timeout = opts.timeout_s,
		intra_stream_timeout = opts.timeout_s,
		max_accept_queue = 8,
		policy = {
			allowed_response_parsers = { strict = true, ['legacy-http1-close'] = true },
			legacy_http1_close_max_response_bytes = 1024 * 1024,
		},
	}))
end

local function count_surfaces_with_prefix(surfaces, prefix)
	local n = 0
	for name in pairs(surfaces or {}) do
		if tostring(name):sub(1, #prefix) == prefix then n = n + 1 end
	end
	return n
end

local function count_poe_surfaces(surfaces)
	local n = 0
	for _, surface in pairs(surfaces or {}) do
		if surface.capabilities and surface.capabilities.poe == true then n = n + 1 end
	end
	return n
end

local function has_known_vlan_mode(surface)
	local mode = surface and surface.attachment and surface.attachment.mode
	return mode == nil or mode == 'hybrid' or mode == 'access' or mode == 'trunk' or mode == 'tunnel'
end

local function sorted_surface_ids(surfaces)
	local ids = {}
	for id in pairs(surfaces or {}) do ids[#ids + 1] = id end
	table.sort(ids, function (a, b) return tostring(a) < tostring(b) end)
	return ids
end

local function choose_probe_surface(surfaces)
	local ids = sorted_surface_ids(surfaces)
	for i = 1, #ids do
		local id = ids[i]
		local s = surfaces[id]
		if tostring(id):match('^GE') and id ~= 'GE8' and s and s.capabilities and s.capabilities.poe == true then
			return id, s
		end
	end
	for i = 1, #ids do
		local id = ids[i]
		if tostring(id):match('^GE') and id ~= 'GE8' then return id, surfaces[id] end
	end
	for i = 1, #ids do
		local id = ids[i]
		if tostring(id):match('^GE') then return id, surfaces[id] end
	end
	local id = ids[1]
	return id, id and surfaces[id] or nil
end

local function new_real_switch_provider(bus, env)
	local provider_conn = bus:connect({ origin_base = { kind = 'local', component = 'rtl8380m-switch-test' } })
	local resolver = assert(hal_deps.resolver(provider_conn))
	return assert(provider_mod.new({
		id = 'switch-main',
		base_url = env.base_url,
		username = env.username,
		password = env.password,
		timeout_s = env.timeout_s,
		openssl_bin = env.openssl_bin,
		include_raw = true,
		http = { response_parser = 'legacy-http1-close' },
	}, { http_client_for = resolver:factory('http_client') }))
end

local function require_successful_snapshot(provider)
	local snap = fibers.perform(provider:snapshot_op({}))
	assert_not_nil(snap, 'snapshot should return a table')
	if snap.ok ~= true then
		local status = snap.status or {}
		error('switch snapshot failed: ' .. tostring(status.err or snap.err or 'unknown error'), 2)
	end
	return snap
end

local function retain_switch_raw(conn, snap)
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'status' }, snap.status or {})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'identity' }, snap.identity or {})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'telemetry' }, snap.telemetry or {})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'surfaces' }, {
		surfaces = snap.surfaces or {},
	})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'topology' }, snap.topology or {})
end

local function retain_device_assembly(conn, observed_surface)
	conn:retain({ 'state', 'device', 'assembly' }, {
		kind = 'device.assembly',
		product = 'big-box',
		components = {
			cm5 = { kind = 'compute', role = 'controller' },
			mcu = { kind = 'microcontroller', role = 'power-sensor-controller' },
			['switch-main'] = { kind = 'switch', role = 'wired-fabric' },
		},
		links = {
			['cm5-switch'] = {
				kind = 'wired',
				role = 'controller-switch-uplink',
				internal = true,
				a = { component = 'cm5', surface = 'eth0' },
				b = { component = 'switch-main', observed_surface = 'GE8' },
			},
		},
		surfaces = {
			['lan-probe'] = {
				kind = 'ethernet',
				exposure = 'external',
				component = 'switch-main',
				observed_surface = observed_surface,
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
				['lan-probe'] = {
					kind = 'ethernet-port',
					role = 'external-observed-port',
					attachment = { mode = 'none' },
				},
			},
		},
	})
end

function T.rtl8380m_real_switch_snapshot_via_http_capability()
	local env, err = required_env()
	if not env then return skip(err) end

	runfibers.run(function ()
		local b = busmod.new()
		local http = start_http_capability(b, env)
		wait_http_available(b)
		local provider = new_real_switch_provider(b, env)
		local snap = require_successful_snapshot(provider)

		assert_eq(snap.provider_id, 'switch-main')
		assert_eq(snap.mode, 'read_only')
		assert_eq(snap.writable, false)
		assert_not_nil(snap.status, 'snapshot should include provider status')
		assert_eq(snap.status.driver, 'rtl8380m_http')
		assert_eq(snap.status.login, 'confirmed')
		assert_true(snap.status.available, 'provider status should be available')

		assert_not_nil(snap.identity, 'snapshot should include identity')
		assert_not_nil(snap.identity.model, 'identity.model should be populated')
		assert_not_nil(snap.identity.mac, 'identity.mac should be populated')
		assert_not_nil(snap.identity.firmware, 'identity.firmware should be populated')

		local surfaces = assert_not_nil(snap.surfaces, 'snapshot should include surfaces')
		assert_true(count_surfaces_with_prefix(surfaces, 'GE') >= 10, 'expected ten GE-labelled switch ports')
		assert_not_nil(surfaces.GE8, 'GE8 should be present as the Big Box CM5 switch-uplink port')
		assert_eq(surfaces.GE9.link.media, 'fiber', 'GE9 should be the first SFP/fibre surface')
		assert_eq(surfaces.GE10.link.media, 'fiber', 'GE10 should be the second SFP/fibre surface')
		assert_true(count_poe_surfaces(surfaces) >= 1, 'expected at least one PoE-capable surface')

		for name, surface in pairs(surfaces) do
			assert_eq(surface.provider_surface_id, name, 'surface id should match table key')
			assert_not_nil(surface.kind, 'surface should have kind')
			assert_not_nil(surface.link, 'surface should have link state')
			assert_not_nil(surface.attachment, 'surface should have attachment state')
			assert_true(has_known_vlan_mode(surface), 'surface ' .. tostring(name) .. ' should have a known VLAN mode')
			if surface.capabilities and surface.capabilities.poe == true then
				assert_not_nil(surface.poe, 'PoE-capable surface should include poe state')
				assert_not_nil(surface.poe.state, 'PoE state should be normalised')
			end
		end

		local raw = assert_not_nil(snap.raw, 'include_raw=true should preserve source payloads')
		assert_not_nil(raw.home_main, 'raw home_main should be captured')
		assert_not_nil(raw.panel_info, 'raw panel_info should be captured')
		assert_not_nil(raw.port_port, 'raw port_port should be captured')
		assert_not_nil(raw.vlan_port, 'raw vlan_port should be captured')
		assert_not_nil(raw.vlan_membership, 'raw vlan_membership should be captured')
		assert_not_nil(raw.poe_poe, 'raw poe_poe should be captured')

		provider:terminate('test complete')
		http:terminate('test complete')
	end, { timeout = env.run_timeout_s })
end

function T.rtl8380m_real_switch_raw_observations_project_to_state_wired()
	local env, err = required_env()
	if not env then return skip(err) end

	runfibers.run(function (scope)
		local b = busmod.new()
		local http = start_http_capability(b, env)
		wait_http_available(b)
		local provider = new_real_switch_provider(b, env)
		local snap = require_successful_snapshot(provider)
		local surfaces = assert_not_nil(snap.surfaces, 'snapshot should include surfaces')
		local probe_id, raw_surface = choose_probe_surface(surfaces)
		assert_not_nil(probe_id, 'snapshot should include a switch surface suitable for projection')
		assert_not_nil(raw_surface, 'chosen switch surface should be present')

		local service_conn = b:connect({ origin_base = { kind = 'local', component = 'wired-service-test' } })
		local writer = b:connect({ origin_base = { kind = 'local', component = 'wired-test-writer' } })
		local reader = b:connect({ origin_base = { kind = 'local', component = 'wired-test-reader' } })

		writer:retain({ 'state', 'net', 'segments' }, { rev = 1, segments = {} })
		retain_device_assembly(writer, probe_id)
		retain_switch_raw(writer, snap)
		retain_wired_config(writer)

		local child = assert(scope:child())
		assert(child:spawn(function (svc_scope) wired_service.run(svc_scope, { conn = service_conn, service_id = 'test-wired' }) end))

		local projected = probe.wait_retained_payload(reader, wired_topics.surface('lan-probe'), { timeout = 2.0 })
		assert_eq(projected.surface_id, 'lan-probe')
		assert_eq(projected.availability.state, 'available')
		assert_eq(projected.provider.provider_id, 'switch-main')
		assert_eq(projected.provider.provider_surface_id, probe_id)
		assert_eq(projected.observed.source.component, 'switch-main')
		assert_eq(projected.observed.source.observed_surface, probe_id)
		assert_eq(projected.observed.source.exposure, 'external')
		assert_eq(projected.link.state, raw_surface.link and raw_surface.link.state)
		if raw_surface.link and raw_surface.link.speed_mbps ~= nil then
			assert_eq(projected.link.speed_mbps, raw_surface.link.speed_mbps)
		end
		assert_eq(projected.observed.attachment.mode, raw_surface.attachment and raw_surface.attachment.mode)
		if raw_surface.capabilities and raw_surface.capabilities.poe == true then
			assert_true(projected.provider.provider_surface_id == probe_id, 'PoE-capable source should still project via assembly')
		end

		local violations = probe.wait_retained_payload(reader, wired_topics.violations(), { timeout = 1.0 })
		assert_eq(#(violations.violations or {}), 0)

		child:cancel('test complete')
		fibers.perform(child:join_op())
		provider:terminate('test complete')
		http:terminate('test complete')
	end, { timeout = env.run_timeout_s })
end

return T
