-- tests/integration/devhost/rtl8380m_switch_spec.lua
--
-- Opt-in devhost test for the real RTL8380M PoE/VLAN switch provider.
--
-- This deliberately talks to a real switch and is therefore skipped unless the
-- operator provides explicit test credentials:
--
--   SWITCH_TEST_BASE_URL=http://192.168.1.1/ \
--   SWITCH_TEST_USERNAME=admin \
--   SWITCH_TEST_PASSWORD=admin \
--   lua tests/run.lua
--
-- The test exercises the production provider through cap/http/main. It does
-- not call lua-http, curl or provider internals directly, and it does not submit
-- any VLAN, PoE, save, reboot or other configuration writes.

local busmod = require 'bus'
local fibers = require 'fibers'

local runfibers = require 'tests.support.run_fibers'
local probe = require 'tests.support.bus_probe'

local http_service = require 'services.http.service'
local device_service = require 'services.device.service'
local device_config  = require 'services.device.config'
local device_topics  = require 'services.device.topics'
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

local function assert_nil(v, msg)
	if v ~= nil then error(msg or ('expected nil, got ' .. tostring(v)), 2) end
end

local function assert_table(v, msg)
	if type(v) ~= 'table' then error(msg or ('expected table, got ' .. type(v)), 2) end
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
	local svc = assert(http_service.open_handle(conn, {
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
	return svc
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


local function wait_retained_payload_where(conn, topic, label, pred, opts)
	opts = opts or {}
	local view = conn:retained_view(opts.view_topic or topic)
	local value = probe.wait_versioned_until(label, function ()
		return view:version()
	end, function (seen)
		return view:changed_op(seen)
	end, function ()
		local msg = view:get(topic)
		local payload = msg and msg.payload or nil
		if pred(payload) then return payload end
		return nil
	end, opts)
	view:close()
	return value
end

local function switch_component_config()
	return {
		schema = device_config.SCHEMA,
		components = {
			['switch-main'] = {
				kind = 'switch',
				module = 'switch',
				class = 'host',
				role = 'switch-fabric',
				member = 'switch-main',
				facts = {
					wired_provider_status = {
						'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'status',
					},
					wired_provider_identity = {
						'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'state', 'identity',
					},
					wired_provider_telemetry = {
						'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'state', 'telemetry',
					},
					wired_provider_surfaces = {
						'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'state', 'surfaces',
					},
					wired_provider_topology = {
						'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'state', 'topology',
					},
				},
			},
		},
	}
end

local function start_device_projection_service(scope, bus)
	local svc_conn = bus:connect({ origin_base = { kind = 'local', component = 'test-device-service' } })
	local caller = bus:connect({ origin_base = { kind = 'local', component = 'test-device-reader' } })
	local child = assert(scope:child())
	local ok, err = child:spawn(function ()
		device_service.start(svc_conn, {
			watch_config = false,
			initial_config = switch_component_config(),
			enable_observers = true,
			enable_actions = false,
			auto_publish = true,
			emit_events = false,
		})
	end)
	assert_true(ok, err)
	probe.wait_retained_payload(caller, device_topics.components(), { timeout = 1.0 })
	return { child = child, caller = caller, svc_conn = svc_conn }
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
	conn:retain({ 'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'status' }, snap.status or {})
	conn:retain({ 'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'state', 'identity' }, snap.identity or {})
	conn:retain({ 'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'state', 'telemetry' }, snap.telemetry or {})
	conn:retain({ 'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'state', 'surfaces' }, {
		surfaces = snap.surfaces or {},
	})
	conn:retain({ 'raw', 'host', 'wired', 'cap', 'wired-provider', 'switch-main', 'state', 'topology' }, snap.topology or {})
end

local function sorted_surface_ids(surfaces)
	local ids = {}
	for id in pairs(surfaces or {}) do ids[#ids + 1] = id end
	table.sort(ids, function (a, b) return tostring(a) < tostring(b) end)
	return ids
end

local function choose_projection_surface(surfaces)
	local ids = sorted_surface_ids(surfaces)
	for i = 1, #ids do
		local id = ids[i]
		local s = surfaces[id]
		if tostring(id):match('^GE') and s and s.capabilities and s.capabilities.poe == true then
			return id, s
		end
	end
	for i = 1, #ids do
		local id = ids[i]
		if tostring(id):match('^GE') then return id, surfaces[id] end
	end
	local id = ids[1]
	return id, id and surfaces[id] or nil
end

local function assert_projected_surface_matches_raw(id, raw_surface, projected_surface)
	assert_not_nil(id, 'expected a surface id to test')
	assert_not_nil(raw_surface, 'expected raw surface ' .. tostring(id))
	assert_not_nil(projected_surface, 'expected projected surface ' .. tostring(id))
	assert_eq(projected_surface.provider_surface_id, raw_surface.provider_surface_id)
	assert_eq(projected_surface.kind, raw_surface.kind)
	assert_not_nil(projected_surface.link, 'projected surface should include link')
	assert_eq(projected_surface.link.state, raw_surface.link and raw_surface.link.state)
	if raw_surface.link and raw_surface.link.speed_mbps ~= nil then
		assert_eq(projected_surface.link.speed_mbps, raw_surface.link.speed_mbps)
	end
	assert_not_nil(projected_surface.attachment, 'projected surface should include attachment')
	assert_eq(projected_surface.attachment.mode, raw_surface.attachment and raw_surface.attachment.mode)
	if raw_surface.attachment and raw_surface.attachment.pvid ~= nil then
		assert_eq(projected_surface.attachment.pvid, raw_surface.attachment.pvid)
	end
	if raw_surface.attachment and raw_surface.attachment.admin_vlans_raw ~= nil then
		assert_eq(projected_surface.attachment.admin_vlans_raw, raw_surface.attachment.admin_vlans_raw)
	end
	if raw_surface.capabilities and raw_surface.capabilities.poe == true then
		assert_true(projected_surface.capabilities and projected_surface.capabilities.poe == true, 'PoE capability should project')
		assert_not_nil(projected_surface.poe, 'PoE-capable projected surface should include poe state')
		assert_eq(projected_surface.poe.state, raw_surface.poe and raw_surface.poe.state)
	end
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
		assert_true(count_surfaces_with_prefix(surfaces, 'GE') >= 8, 'expected at least eight GE ports')
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


function T.rtl8380m_real_switch_device_projects_raw_wired_provider_state()
	local env, err = required_env()
	if not env then return skip(err) end

	runfibers.run(function (scope)
		local b = busmod.new()
		local http = start_http_capability(b, env)
		wait_http_available(b)

		local provider = new_real_switch_provider(b, env)
		local snap = require_successful_snapshot(provider)
		local raw_identity = assert_not_nil(snap.identity, 'snapshot should include provider identity')
		local raw_telemetry = assert_not_nil(snap.telemetry, 'snapshot should include provider telemetry')
		local raw_surfaces = assert_not_nil(snap.surfaces, 'snapshot should include raw provider surfaces')
		local probe_id, raw_surface = choose_projection_surface(raw_surfaces)
		assert_not_nil(probe_id, 'snapshot should include at least one switch surface')

		local device = start_device_projection_service(scope, b)
		retain_switch_raw(device.caller, snap)

		local component = wait_retained_payload_where(
			device.caller,
			device_topics.component('switch-main'),
			'switch-main component projects raw wired-provider facts',
			function (p)
				local wp = p and p.wired_provider
				local surfaces = wp and wp.surfaces or {}
				return p
					and p.component == 'switch-main'
					and p.available == true
					and p.runtime
					and p.runtime.driver == 'rtl8380m_http'
					and wp
					and wp.status
					and wp.status.login == 'confirmed'
					and wp.identity
					and wp.identity.model == raw_identity.model
					and wp.telemetry
					and wp.telemetry.poe
					and surfaces[probe_id] ~= nil
			end,
			{ timeout = 2.0 }
		)

		assert_eq(component.kind, 'device.component')
		assert_eq(component.class, 'host')
		assert_eq(component.role, 'switch-fabric')
		assert_eq(component.member, 'switch-main')
		assert_eq(component.runtime.provider_mode, 'read_only')
		assert_eq(component.runtime.driver, 'rtl8380m_http')
		assert_eq(component.wired_provider.status.driver, 'rtl8380m_http')
		assert_eq(component.wired_provider.status.login, 'confirmed')
		assert_eq(component.wired_provider.identity.model, raw_identity.model)
		assert_eq(component.wired_provider.identity.mac, raw_identity.mac)
		assert_eq(component.wired_provider.identity.firmware, raw_identity.firmware)
		assert_eq(component.wired_provider.telemetry.poe.dev_temp_c, raw_telemetry.poe and raw_telemetry.poe.dev_temp_c)
		local component_health = assert_table(component.health, 'component health should be a structured health object')
		assert_eq(component_health.health, 'ok')
		assert_nil(component_health.fault)
		assert_eq(component_health.details.driver, 'rtl8380m_http')
		assert_eq(component_health.details.login, 'confirmed')
		assert_eq(component_health.details.available, true)
		assert_eq(component_health.details.mode, 'read_only')
		assert_projected_surface_matches_raw(probe_id, raw_surface, component.wired_provider.surfaces[probe_id])

		local cap_status = wait_retained_payload_where(
			device.caller,
			device_topics.wired_provider_cap_status('switch-main'),
			'switch-main public wired-provider status projected',
			function (p) return p and p.available == true and p.mode == 'read_only' end,
			{ timeout = 2.0 }
		)
		assert_eq(cap_status.state, 'available')
		assert_eq(cap_status.available, true)
		assert_eq(cap_status.mode, 'read_only')
		local cap_health = assert_table(cap_status.health, 'wired-provider cap health should be a structured health object')
		assert_eq(cap_health.health, 'ok')
		assert_nil(cap_health.fault)
		assert_eq(cap_health.details.driver, 'rtl8380m_http')
		assert_eq(cap_health.details.login, 'confirmed')
		assert_eq(cap_health.details.available, true)
		assert_eq(cap_health.details.mode, 'read_only')

		local cap_identity = probe.wait_retained_payload(
			device.caller,
			device_topics.wired_provider_cap_state('switch-main', 'identity'),
			{ timeout = 1.0 }
		)
		assert_eq(cap_identity.model, raw_identity.model)
		assert_eq(cap_identity.mac, raw_identity.mac)
		assert_eq(cap_identity.firmware, raw_identity.firmware)

		local cap_telemetry = probe.wait_retained_payload(
			device.caller,
			device_topics.wired_provider_cap_state('switch-main', 'telemetry'),
			{ timeout = 1.0 }
		)
		assert_eq(cap_telemetry.poe.dev_temp_c, raw_telemetry.poe and raw_telemetry.poe.dev_temp_c)

		local cap_surfaces = probe.wait_retained_payload(
			device.caller,
			device_topics.wired_provider_cap_state('switch-main', 'surfaces'),
			{ timeout = 1.0 }
		)
		local projected_surfaces = assert_not_nil(cap_surfaces.surfaces, 'public cap should wrap surfaces')
		assert_projected_surface_matches_raw(probe_id, raw_surface, projected_surfaces[probe_id])

		local cap_topology = probe.wait_retained_payload(
			device.caller,
			device_topics.wired_provider_cap_state('switch-main', 'topology'),
			{ timeout = 1.0 }
		)
		assert_eq(cap_topology.provider, snap.topology and snap.topology.provider)

		local cap_meta = probe.wait_retained_payload(
			device.caller,
			device_topics.wired_provider_cap_meta('switch-main'),
			{ timeout = 1.0 }
		)
		assert_eq(cap_meta.owner, 'device')
		assert_eq(cap_meta.interface, 'devicecode.cap/wired-provider/1')
		assert_eq(cap_meta.backing.facts.wired_provider_status[1], 'raw')
		assert_eq(cap_meta.backing.facts.wired_provider_status[2], 'host')
		assert_eq(cap_meta.backing.facts.wired_provider_status[3], 'wired')

		provider:terminate('test complete')
		http:terminate('test complete')
		device.child:cancel('test complete')
	end, { timeout = env.run_timeout_s })
end

return T
