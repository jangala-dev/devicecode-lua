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


return T
