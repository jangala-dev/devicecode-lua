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
-- not submit VLAN, PoE, save, reboot or other configuration writes.  The fixed timing tests use http://192.168.1.1/ with admin/admin when their
-- SWITCH_TEST_FIXED_SWITCH_* flag is set.

local busmod = require 'bus'
local fibers = require 'fibers'
local pulse = require 'fibers.pulse'
local runtime = require 'fibers.runtime'

local runfibers = require 'tests.support.run_fibers'
local probe = require 'tests.support.bus_probe'

local http_service = require 'services.http.service'
local wired_service = require 'services.wired.service'
local wired_config  = require 'services.wired.config'
local wired_topics  = require 'services.wired.topics'
local provider_mod = require 'services.hal.backends.wired.providers.rtl8380m_http'
local hal_deps = require 'services.hal.dependencies'

local T = {}

local DEFAULT_TIMING_GROUPS = {
	'home_main',
	'panel_info',
	'panel',
	'identity',
	'port',
	'vlan_create',
	'vlan_conf',
	'vlan_port',
	'vlan_membership',
	'vlan',
	'poe',
	'lldp_local',
	'lldp_neighbor',
	'lldp',
	'runtime',
	'counters',
	'stats',
	'full',
}

local DEFAULT_CONCURRENT_TIMING_GROUPS = {
	'panel',
	'poe',
	'counters',
	'runtime',
}

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

local function fixed_stats_env()
	if os.getenv('SWITCH_TEST_FIXED_SWITCH_STATS') ~= '1' then
		return nil, 'set SWITCH_TEST_FIXED_SWITCH_STATS=1 to run the fixed 192.168.1.1 stats timing test'
	end
	return {
		base_url = 'http://192.168.1.1/',
		username = 'admin',
		password = 'admin',
		timeout_s = tonumber(os.getenv('SWITCH_TEST_STATS_TIMEOUT_S') or '1.2') or 1.2,
		run_timeout_s = tonumber(os.getenv('SWITCH_TEST_RUN_TIMEOUT_S') or '30') or 30,
		stats_budget_s = tonumber(os.getenv('SWITCH_TEST_STATS_BUDGET_S') or '2.5') or 2.5,
		openssl_bin = os.getenv('SWITCH_TEST_OPENSSL') or os.getenv('SWITCH_OPENSSL') or 'openssl',
	}
end

local function fixed_panel_env()
	if os.getenv('SWITCH_TEST_FIXED_SWITCH_PANEL_TIMING') ~= '1' then
		return nil, 'set SWITCH_TEST_FIXED_SWITCH_PANEL_TIMING=1 to run the fixed 192.168.1.1 panel timing test'
	end
	return {
		base_url = 'http://192.168.1.1/',
		username = 'admin',
		password = 'admin',
		timeout_s = tonumber(os.getenv('SWITCH_TEST_PANEL_TIMEOUT_S') or '0.75') or 0.75,
		run_timeout_s = tonumber(os.getenv('SWITCH_TEST_RUN_TIMEOUT_S') or '30') or 30,
		panel_budget_s = tonumber(os.getenv('SWITCH_TEST_PANEL_BUDGET_S') or '1.0') or 1.0,
		panel_iterations = tonumber(os.getenv('SWITCH_TEST_PANEL_ITERATIONS') or '10') or 10,
		openssl_bin = os.getenv('SWITCH_TEST_OPENSSL') or os.getenv('SWITCH_OPENSSL') or 'openssl',
	}
end

local function split_csv(s)
	local out = {}
	for token in tostring(s or ''):gmatch('[^,%s]+') do out[#out + 1] = token end
	return out
end

local function fixed_timing_env()
	if os.getenv('SWITCH_TEST_FIXED_SWITCH_TIMING') ~= '1' then
		return nil, 'set SWITCH_TEST_FIXED_SWITCH_TIMING=1 to run the fixed 192.168.1.1 command timing sweep'
	end
	local groups = split_csv(os.getenv('SWITCH_TEST_TIMING_GROUPS'))
	if #groups == 0 then groups = DEFAULT_TIMING_GROUPS end
	return {
		base_url = 'http://192.168.1.1/',
		username = 'admin',
		password = 'admin',
		timeout_s = tonumber(os.getenv('SWITCH_TEST_TIMING_TIMEOUT_S') or '2.5') or 2.5,
		run_timeout_s = tonumber(os.getenv('SWITCH_TEST_RUN_TIMEOUT_S') or '60') or 60,
		iterations = tonumber(os.getenv('SWITCH_TEST_TIMING_ITERATIONS') or '3') or 3,
		require_all = os.getenv('SWITCH_TEST_TIMING_REQUIRE_ALL') == '1',
		groups = groups,
		openssl_bin = os.getenv('SWITCH_TEST_OPENSSL') or os.getenv('SWITCH_OPENSSL') or 'openssl',
	}
end

local function fixed_concurrent_timing_env()
	if os.getenv('SWITCH_TEST_FIXED_SWITCH_CONCURRENT_TIMING') ~= '1' then
		return nil, 'set SWITCH_TEST_FIXED_SWITCH_CONCURRENT_TIMING=1 to run the fixed 192.168.1.1 concurrent command timing test'
	end
	local groups = split_csv(os.getenv('SWITCH_TEST_CONCURRENT_GROUPS'))
	if #groups == 0 then groups = DEFAULT_CONCURRENT_TIMING_GROUPS end
	return {
		base_url = 'http://192.168.1.1/',
		username = 'admin',
		password = 'admin',
		timeout_s = tonumber(os.getenv('SWITCH_TEST_CONCURRENT_TIMEOUT_S') or '2.5') or 2.5,
		run_timeout_s = tonumber(os.getenv('SWITCH_TEST_RUN_TIMEOUT_S') or '60') or 60,
		iterations = tonumber(os.getenv('SWITCH_TEST_CONCURRENT_ITERATIONS') or '3') or 3,
		require_all = os.getenv('SWITCH_TEST_CONCURRENT_REQUIRE_ALL') == '1',
		budget_s = tonumber(os.getenv('SWITCH_TEST_CONCURRENT_BUDGET_S') or ''),
		groups = groups,
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

local function count_link_states(surfaces)
	local up, down = 0, 0
	for _, surface in pairs(surfaces or {}) do
		local state = surface.link and surface.link.state
		if state == 'up' then up = up + 1
		elseif state == 'down' then down = down + 1 end
	end
	return up, down
end

local function count_table_keys(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function command_result_raw_count(result)
	return count_table_keys(result and result.raw or nil)
end


local function summarise_command_result(result)
	if result and result.ok == true then
		return true, command_result_raw_count(result), nil
	end
	local status = result and result.status or {}
	return false, 0, tostring(status.err or (result and result.err) or 'unknown error')
end

local function run_command_groups_sequential(provider, groups)
	local results = {}
	local started = runtime.now()
	for i, group in ipairs(groups) do
		local group_started = runtime.now()
		local result = fibers.perform(provider:command_group_op({ group = group }))
		local ok, raw_count, err = summarise_command_result(result)
		results[i] = { group = group, ok = ok, raw_count = raw_count, err = err, elapsed_s = runtime.now() - group_started }
	end
	return runtime.now() - started, results
end

local function run_command_groups_concurrent(scope, provider, groups)
	local results = {}
	local done = pulse.new()
	local seen = done:version()
	local remaining = #groups
	local started = runtime.now()

	if remaining == 0 then return 0, results end

	for i, group in ipairs(groups) do
		local ok_spawn, spawn_err = scope:spawn(function ()
			local group_started = runtime.now()
			local result = fibers.perform(provider:command_group_op({ group = group }))
			local ok, raw_count, err = summarise_command_result(result)
			results[i] = { group = group, ok = ok, raw_count = raw_count, err = err, elapsed_s = runtime.now() - group_started }
			remaining = remaining - 1
			if remaining == 0 then done:signal() end
		end)
		if not ok_spawn then error(spawn_err, 2) end
	end

	if remaining > 0 then fibers.perform(done:changed_op(seen)) end
	return runtime.now() - started, results
end

local function count_command_result_failures(results)
	local ok_count, fail_count, raw_total, last_err = 0, 0, 0, nil
	for _, result in ipairs(results or {}) do
		if result.ok == true then
			ok_count = ok_count + 1
			raw_total = raw_total + (result.raw_count or 0)
		else
			fail_count = fail_count + 1
			last_err = result.group .. ': ' .. tostring(result.err or 'failed')
		end
	end
	return ok_count, fail_count, raw_total, last_err
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
		base_url = env.base_url,
		username = env.username,
		password = env.password,
		timeout_s = env.timeout_s,
		openssl_bin = env.openssl_bin,
		include_raw = true,
		http = { capability = 'main', response_parser = 'legacy-http1-close' },
	}, { provider_id = 'switch-main', http_client_for = resolver:factory('http_client') }))
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
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'runtime' }, snap.runtime or {})
	conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'power' }, snap.power or {})
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
				a = { component = 'cm5', observed_surface = 'eth0' },
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

		assert_not_nil(snap.runtime, 'snapshot should include runtime')
		assert_not_nil(snap.runtime.cpu, 'runtime.cpu should be present')
		assert_not_nil(snap.runtime.memory, 'runtime.memory should be present')
		assert_not_nil(snap.power, 'snapshot should include power')
		assert_not_nil(snap.power.poe, 'power.poe should be present')

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
		assert_not_nil(raw.sys_cpumem, 'raw sys_cpumem should be captured')
		assert_not_nil(raw.rmon_statistics, 'raw rmon_statistics should be captured')

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
		assert_eq(projected.source.component, 'switch-main')
		assert_eq(projected.source.observed_surface, probe_id)
		assert_eq(projected.observed.source.component, 'switch-main')
		assert_eq(projected.observed.source.observed_surface, probe_id)
		assert_eq(projected.observed.source.exposure, 'external')
		assert_eq(projected.link.state, raw_surface.link and raw_surface.link.state)
		if raw_surface.link and raw_surface.link.speed_mbps ~= nil then
			assert_eq(projected.link.speed_mbps, raw_surface.link.speed_mbps)
		end
		assert_eq(projected.observed.attachment.mode, raw_surface.attachment and raw_surface.attachment.mode)
		if raw_surface.counters and raw_surface.counters.rx and raw_surface.counters.rx.bytes ~= nil then
			assert_eq(projected.counters.rx.bytes, raw_surface.counters.rx.bytes)
		end
		if raw_surface.capabilities and raw_surface.capabilities.poe == true then
			assert_true(projected.source.observed_surface == probe_id, 'PoE-capable source should still project via assembly')
		end

		local violations = probe.wait_retained_payload(reader, wired_topics.violations(), { timeout = 1.0 })
		assert_eq(#(violations.violations or {}), 0)

		child:cancel('test complete')
		fibers.perform(child:join_op())
		provider:terminate('test complete')
		http:terminate('test complete')
	end, { timeout = env.run_timeout_s })
end


function T.rtl8380m_fixed_switch_admin_stats_within_allotted_time()
	local env, err = fixed_stats_env()
	if not env then return skip(err) end

	runfibers.run(function ()
		local b = busmod.new()
		local http = start_http_capability(b, env)
		wait_http_available(b)
		local provider = new_real_switch_provider(b, env)

		-- Warm the authenticated session once.  The timing assertion below is for
		-- the stats read using the retained session, not for RSA login.
		local warm = require_successful_snapshot(provider)
		assert_eq(warm.status.login, 'confirmed')

		local started = runtime.now()
		local stats = fibers.perform(provider:stats_op({}))
		local elapsed = runtime.now() - started
		assert_not_nil(stats, 'stats_op should return a table')
		if stats.ok ~= true then
			local status = stats.status or {}
			error('switch stats failed: ' .. tostring(status.err or stats.err or 'unknown error'), 2)
		end
		assert_true(elapsed <= env.stats_budget_s, ('stats elapsed %.3fs exceeded budget %.3fs'):format(elapsed, env.stats_budget_s))
		assert_eq(stats.status.login, 'confirmed')
		assert_not_nil(stats.runtime, 'stats should include runtime')
		assert_not_nil(stats.runtime.cpu, 'stats should include runtime.cpu')
		assert_not_nil(stats.runtime.memory, 'stats should include runtime.memory')
		assert_not_nil(stats.raw, 'include_raw=true should preserve stats payloads')
		assert_not_nil(stats.raw.sys_cpumem, 'stats raw sys_cpumem should be captured')
		assert_not_nil(stats.raw.rmon_statistics, 'stats raw rmon_statistics should be captured')

		provider:terminate('test complete')
		http:terminate('test complete')
	end, { timeout = env.run_timeout_s })
end

function T.rtl8380m_fixed_switch_admin_panel_timing()
	local env, err = fixed_panel_env()
	if not env then return skip(err) end

	runfibers.run(function ()
		local b = busmod.new()
		local http = start_http_capability(b, env)
		wait_http_available(b)
		local provider = new_real_switch_provider(b, env)

		-- Warm login using the same cheap panel path.  The timed loop below
		-- measures retained-session panel reads only; it does not run a full
		-- switch snapshot and therefore does not depend on sys_cpumem or RMON.
		local warm = fibers.perform(provider:panel_op({}))
		assert_not_nil(warm, 'panel_op should return a table')
		if warm.ok ~= true then
			local status = warm.status or {}
			error('switch panel warm-up failed: ' .. tostring(status.err or warm.err or 'unknown error'), 2)
		end
		assert_eq(warm.status.login, 'confirmed')

		local min_s, max_s, total_s = nil, 0, 0
		local last_panel
		for _ = 1, env.panel_iterations do
			local started = runtime.now()
			local panel = fibers.perform(provider:panel_op({}))
			local elapsed = runtime.now() - started
			assert_not_nil(panel, 'panel_op should return a table')
			if panel.ok ~= true then
				local status = panel.status or {}
				error('switch panel read failed: ' .. tostring(status.err or panel.err or 'unknown error'), 2)
			end
			last_panel = panel
			if min_s == nil or elapsed < min_s then min_s = elapsed end
			if elapsed > max_s then max_s = elapsed end
			total_s = total_s + elapsed
			assert_true(elapsed <= env.panel_budget_s, ('panel read elapsed %.3fs exceeded budget %.3fs'):format(elapsed, env.panel_budget_s))
		end

		local surface_count = count_surfaces_with_prefix(last_panel.surfaces, 'GE')
		local up, down = count_link_states(last_panel.surfaces)
		assert_true(surface_count >= 10, 'panel read should expose the ten GE switch surfaces')
		assert_true((up + down) >= 10, 'panel read should expose link state for switch surfaces')
		io.stderr:write(('rtl8380m panel timing: n=%d min=%.3fs avg=%.3fs max=%.3fs ge=%d link_up=%d link_down=%d\n'):format(
			env.panel_iterations,
			min_s or 0,
			total_s / env.panel_iterations,
			max_s,
			surface_count,
			up,
			down
		))

		provider:terminate('test complete')
		http:terminate('test complete')
	end, { timeout = env.run_timeout_s })
end


function T.rtl8380m_fixed_switch_admin_command_timing_sweep()
	local env, err = fixed_timing_env()
	if not env then return skip(err) end

	runfibers.run(function ()
		local b = busmod.new()
		local http = start_http_capability(b, env)
		wait_http_available(b)
		local provider = new_real_switch_provider(b, env)

		local warm = fibers.perform(provider:panel_op({}))
		assert_not_nil(warm, 'panel warm-up should return a table')
		if warm.ok ~= true then
			local status = warm.status or {}
			error('switch panel warm-up failed: ' .. tostring(status.err or warm.err or 'unknown error'), 2)
		end

		local any_ok = false
		local failures = {}
		for _, group in ipairs(env.groups) do
			local min_s, max_s, total_s = nil, 0, 0
			local ok_count, fail_count, raw_count = 0, 0, 0
			local last_err
			for _ = 1, env.iterations do
				local started = runtime.now()
				local result = fibers.perform(provider:command_group_op({ group = group }))
				local elapsed = runtime.now() - started
				if min_s == nil or elapsed < min_s then min_s = elapsed end
				if elapsed > max_s then max_s = elapsed end
				total_s = total_s + elapsed
				if result and result.ok == true then
					ok_count = ok_count + 1
					any_ok = true
					raw_count = command_result_raw_count(result)
				else
					fail_count = fail_count + 1
					local status = result and result.status or {}
					last_err = tostring(status.err or (result and result.err) or 'unknown error')
				end
			end
			local avg_s = total_s / env.iterations
			io.stderr:write(('rtl8380m command timing: group=%s n=%d ok=%d fail=%d min=%.3fs avg=%.3fs max=%.3fs raw_keys=%d%s\n'):format(
				group,
				env.iterations,
				ok_count,
				fail_count,
				min_s or 0,
				avg_s,
				max_s,
				raw_count,
				last_err and (' last_err=' .. last_err) or ''
			))
			if env.require_all and fail_count > 0 then failures[#failures + 1] = group .. ': ' .. tostring(last_err or 'failed') end
		end

		assert_true(any_ok, 'at least one switch command timing group should succeed')
		if env.require_all and #failures > 0 then error('switch timing failures: ' .. table.concat(failures, '; '), 2) end

		provider:terminate('test complete')
		http:terminate('test complete')
	end, { timeout = env.run_timeout_s })
end

function T.rtl8380m_fixed_switch_admin_concurrent_command_timing()
	local env, err = fixed_concurrent_timing_env()
	if not env then return skip(err) end

	runfibers.run(function (scope)
		local b = busmod.new()
		local http = start_http_capability(b, env)
		wait_http_available(b)
		local provider = new_real_switch_provider(b, env)

		local warm = fibers.perform(provider:panel_op({}))
		assert_not_nil(warm, 'panel warm-up should return a table')
		if warm.ok ~= true then
			local status = warm.status or {}
			error('switch panel warm-up failed: ' .. tostring(status.err or warm.err or 'unknown error'), 2)
		end

		local seq_total, conc_total = 0, 0
		local best_seq, best_conc, worst_seq, worst_conc = nil, nil, 0, 0
		local any_ok = false
		local failures = {}
		local group_list = table.concat(env.groups, ',')

		for i = 1, env.iterations do
			local seq_elapsed, seq_results = run_command_groups_sequential(provider, env.groups)
			local seq_ok, seq_fail, seq_raw, seq_err = count_command_result_failures(seq_results)

			local conc_elapsed, conc_results = run_command_groups_concurrent(scope, provider, env.groups)
			local conc_ok, conc_fail, conc_raw, conc_err = count_command_result_failures(conc_results)

			seq_total = seq_total + seq_elapsed
			conc_total = conc_total + conc_elapsed
			if best_seq == nil or seq_elapsed < best_seq then best_seq = seq_elapsed end
			if best_conc == nil or conc_elapsed < best_conc then best_conc = conc_elapsed end
			if seq_elapsed > worst_seq then worst_seq = seq_elapsed end
			if conc_elapsed > worst_conc then worst_conc = conc_elapsed end
			if seq_ok > 0 or conc_ok > 0 then any_ok = true end

			local speedup = conc_elapsed > 0 and (seq_elapsed / conc_elapsed) or 0
			io.stderr:write(('rtl8380m concurrent timing: iter=%d groups=%s sequential=%.3fs concurrent=%.3fs speedup=%.2fx seq_ok=%d seq_fail=%d conc_ok=%d conc_fail=%d raw_seq=%d raw_conc=%d%s%s\n'):format(
				i,
				group_list,
				seq_elapsed,
				conc_elapsed,
				speedup,
				seq_ok,
				seq_fail,
				conc_ok,
				conc_fail,
				seq_raw,
				conc_raw,
				seq_err and (' seq_err=' .. seq_err) or '',
				conc_err and (' conc_err=' .. conc_err) or ''
			))

			if env.budget_s and conc_elapsed > env.budget_s then
				failures[#failures + 1] = ('iteration %d concurrent %.3fs exceeded budget %.3fs'):format(i, conc_elapsed, env.budget_s)
			end
			if env.require_all and (seq_fail > 0 or conc_fail > 0) then
				failures[#failures + 1] = ('iteration %d failures: seq=%s conc=%s'):format(i, tostring(seq_err), tostring(conc_err))
			end
		end

		io.stderr:write(('rtl8380m concurrent timing summary: n=%d groups=%s seq_avg=%.3fs seq_min=%.3fs seq_max=%.3fs conc_avg=%.3fs conc_min=%.3fs conc_max=%.3fs speedup=%.2fx\n'):format(
			env.iterations,
			group_list,
			seq_total / env.iterations,
			best_seq or 0,
			worst_seq,
			conc_total / env.iterations,
			best_conc or 0,
			worst_conc,
			conc_total > 0 and (seq_total / conc_total) or 0
		))

		assert_true(any_ok, 'at least one sequential or concurrent command group read should succeed')
		if #failures > 0 then error('switch concurrent timing failures: ' .. table.concat(failures, '; '), 2) end

		provider:terminate('test complete')
		http:terminate('test complete')
	end, { timeout = env.run_timeout_s })
end

return T
