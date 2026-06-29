local fibers = require 'fibers'
local provider = require 'services.hal.backends.wired.providers.rtl8380m_http'
local ok_cjson, cjson = pcall(require, 'cjson.safe')
if not ok_cjson then cjson = require 'cjson' end

local tests = {}
local function assert_true(v,msg) if v ~= true then error(msg or 'expected true',2) end end
local function assert_eq(a,b,msg) if a ~= b then error(msg or ('expected '..tostring(b)..', got '..tostring(a)),2) end end
local function assert_not_nil(v,msg) if v == nil then error(msg or 'expected non-nil',2) end end


function tests.test_wired_manager_provider_ids_are_config_driven()
	local manager = require 'services.hal.managers.wired'
	local ids, err = manager._test.normalise_provider_ids({
		providers = {
			['cm5-local-wired'] = { provider = 'static' },
			['expansion-a'] = { provider = 'static' },
		},
	})
	assert_not_nil(ids, err)
	assert_eq(#ids, 2)
	assert_eq(ids[1], 'cm5-local-wired')
	assert_eq(ids[2], 'expansion-a')

	ids, err = manager._test.normalise_provider_ids({ providers = {} })
	assert_not_nil(ids, err)
	assert_eq(#ids, 0)
end


function tests.test_wired_manager_provider_ids_must_be_map_keys()
	local manager = require 'services.hal.managers.wired'
	local ids, err = manager._test.normalise_provider_ids({
		providers = {
			['switch-main'] = { provider = 'rtl8380m_http', id = 'legacy-id' },
		},
	})
	assert_eq(ids, nil)
	assert_true(type(err) == 'string' and err:find('map key', 1, true) ~= nil, tostring(err))
end


function tests.test_wired_provider_loader_requires_provider_field()
	local loader = require 'services.hal.backends.wired.provider'
	local p, err = loader.new({}, { provider_id = 'x' })
	assert_eq(p, nil)
	assert_true(type(err) == 'string' and err:find('requires provider', 1, true) ~= nil, tostring(err))
end

function tests.test_static_provider_requires_manager_provider_id_and_surfaces()
	local static = require 'services.hal.backends.wired.providers.static'
	local p, err = static.new({ provider = 'static', surfaces = { eth0 = {} } }, {})
	assert_eq(p, nil)
	assert_true(type(err) == 'string' and err:find('provider_id', 1, true) ~= nil, tostring(err))

	p, err = static.new({ provider = 'static' }, { provider_id = 'cm5-local-wired' })
	assert_eq(p, nil)
	assert_true(type(err) == 'string' and err:find('surfaces', 1, true) ~= nil, tostring(err))
end

function tests.test_rtl8380m_http_requires_canonical_provider_and_http_config()
	local p, err = provider.new({
		id = 'switch-main',
		base_url = 'http://192.168.1.1/',
		username = 'admin',
		password = 'admin',
		timeout_s = 0.8,
		http = { capability = 'main', response_parser = 'legacy-http1-close' },
	}, { provider_id = 'switch-main', http_client_for = function () return { exchange_op = function () end } end })
	assert_eq(p, nil)
	assert_true(type(err) == 'string' and err:find('id', 1, true) ~= nil, tostring(err))

	p, err = provider.new({
		base_url = '192.168.1.1/',
		username = 'admin',
		password = 'admin',
		timeout_s = 0.8,
		http = { capability = 'main', response_parser = 'legacy-http1-close' },
	}, { provider_id = 'switch-main', http_client_for = function () return { exchange_op = function () end } end })
	assert_eq(p, nil)
	assert_true(type(err) == 'string' and err:find('scheme', 1, true) ~= nil, tostring(err))

	p, err = provider.new({
		base_url = 'http://192.168.1.1/',
		username = 'admin',
		password = 'admin',
		timeout_s = 0.8,
		http = { capability = 'main' },
	}, { provider_id = 'switch-main', http_client_for = function () return { exchange_op = function () end } end })
	assert_eq(p, nil)
	assert_true(type(err) == 'string' and err:find('response_parser', 1, true) ~= nil, tostring(err))
end


function tests.test_rtl8380m_http_snapshot_uses_legacy_http1_close_parser_for_cgi()
	fibers.run(function ()
		local seen = {}
		local payloads = {
			home_main = { ports = { { port = 'GE1' }, { port = 'GE9' } }, model = 'RTL8380' },
			panel_info = { ports = { { linkup = true, speed = '100', dupFull = true }, { linkup = false, media = 'fiber' } } },
			sys_sysinfo = { hostname = 'Switch', sysMac = '00:E0:5C:24:16:39', fwVer = '1.0.0.6', loaderVer = '3.6.7.55090', currIpv4 = '192.168.1.1' },
			port_port = { ports = { { adminStatus = true, operStatus = true, operSpeed = '100M', operDuplex = 'Full', type = '1000M Copper' }, { adminStatus = true, operStatus = false, type = '1000M Fiber' } } },
			vlan_create = { vlans = { { vlan = 1, name = 'default' } } },
			vlan_conf = { vlan = 1, ports = { { membership = 3, pvid = true, forbidden = false }, { membership = 3, pvid = true, forbidden = false } } },
			vlan_port = { ports = { { mode = 2, pvid = 1, accFrameType = 0, ingressFilter = true, tpid = '0x8100' }, { mode = 2, pvid = 1, accFrameType = 0, ingressFilter = true, tpid = '0x8100' } } },
			vlan_membership = { ports = { { adminVlans = '1UP', operVlans = '1UP' }, { adminVlans = '1UP', operVlans = '1UP' } } },
			poe_poe = { devPower = 0, devTemp = 28, ports = { { portEnable = true, portStatus = false, portType = 'N/A', portPowerLimit = 0 } } },
			sys_cpumem = { cpu = 3, mem = 61 },
			rmon_statistics = { ports = { { bytesRec = 1234, pktsRec = 12, dropEvents = 1, CRCAlignErr = 2, bPktsRec = 3, mPktsRec = 4 } } },
			lldp_local = {},
			lldp_neighbor = {},
		}
		local http_ref = {
			exchange_op = function(_, args)
				return fibers.run_scope_op(function ()
					assert_eq(args.response_parser, 'legacy-http1-close', 'CGI request should ask HTTP service for legacy HTTP/1 close parsing')
					assert_eq(args.timeout_s, 8)
					assert_not_nil(args.max_response_bytes, 'legacy CGI requests should be bounded')
					seen[#seen + 1] = args.uri
					local cmd = tostring(args.uri):match('cmd=([^&]+)')
					local body = cjson.encode({ data = payloads[cmd] or {} })
					local ok, err = fibers.perform(args.response_sink:write_chunk_op(body))
					assert_true(ok, tostring(err))
					return { result = { status = '200', headers = {} } }
				end):wrap(function (status, _report, result_or_primary, err)
					if status == 'ok' then return result_or_primary, err end
					return nil, result_or_primary or status
				end)
			end,
		}
		local p = assert(provider.new({
			base_url = 'http://192.168.1.1/',
			username = 'admin',
			password = 'admin',
			timeout_s = 8,
			disable_login = true,
			http = { capability = 'main', response_parser = 'legacy-http1-close' },
		}, {
			provider_id = 'switch-main',
			http_client_for = function () return http_ref end,
		}))
		local snap = fibers.perform(p:snapshot_op({}))
		assert_true(snap.ok, snap.status and snap.status.err)
		assert_eq(snap.surfaces.GE1.link.state, 'up')
		assert_eq(snap.surfaces.GE1.link.speed_mbps, 100)
		assert_eq(snap.surfaces.GE1.attachment.mode, 'trunk')
		assert_eq(snap.surfaces.GE1.attachment.accept_frame_type, 'all')
		assert_true(snap.surfaces.GE1.capabilities.poe)
		assert_eq(snap.runtime.cpu.utilisation_pct, 3)
		assert_eq(snap.runtime.memory.utilisation_pct, 61)
		assert_eq(snap.power.poe.temperature_c, 28)
		assert_eq(snap.surfaces.GE1.counters.rx.bytes, 1234)
		assert_eq(snap.surfaces.GE1.counters.rx.errors, 2)
		assert_eq(snap.surfaces.GE9.link.media, 'fiber')
		assert_true(#seen >= 10, 'expected seeded CGI snapshot reads')
	end)
end


function tests.test_rtl8380m_http_accepts_narrow_http_client_factory()
	fibers.run(function ()
		local requested
		local calls = 0
		local http_ref = {
			exchange_op = function(_, args)
				calls = calls + 1
				return fibers.run_scope_op(function ()
					assert_eq(args.response_parser, 'legacy-http1-close')
					local cmd = tostring(args.uri):match('cmd=([^&]+)')
					local payloads = {
						home_main = { ports = { { port = 'GE1' } }, model = 'RTL8380' },
						panel_info = { ports = { { linkup = false } } },
						sys_sysinfo = { hostname = 'Switch' },
						port_port = { ports = { {} } },
						vlan_create = {},
						vlan_conf = { ports = { {} } },
						vlan_port = { ports = { {} } },
						vlan_membership = { ports = { {} } },
						poe_poe = { ports = {} },
						sys_cpumem = {},
						rmon_statistics = { ports = {} },
						lldp_local = {},
						lldp_neighbor = {},
					}
					local body = cjson.encode({ data = payloads[cmd] or {} })
					local ok, err = fibers.perform(args.response_sink:write_chunk_op(body))
					assert_true(ok, tostring(err))
					return { result = { status = '200', headers = {} } }
				end):wrap(function (status, _report, result_or_primary, err)
					if status == 'ok' then return result_or_primary, err end
					return nil, result_or_primary or status
				end)
			end,
		}
		local p = assert(provider.new({
			base_url = 'http://192.168.1.1/',
			username = 'admin',
			password = 'admin',
			timeout_s = 8,
			disable_login = true,
			http = { capability = 'switch-http', response_parser = 'legacy-http1-close' },
		}, {
			provider_id = 'switch-main',
			http_client_for = function (cap_id)
				requested = cap_id
				return http_ref
			end,
		}))
		local snap = fibers.perform(p:snapshot_op({}))
		assert_true(snap.ok, snap.status and snap.status.err)
		assert_eq(requested, 'switch-http')
		assert_true(calls >= 10, 'expected snapshot CGI calls through HTTP dependency port')
	end)
end



function tests.test_wired_driver_separates_backend_provider_name_and_provider_id()
	local driver_mod = require 'services.hal.drivers.wired'
	local d, err = driver_mod.new({
		provider = 'static',
		mode = 'read_only',
		surfaces = { eth0 = { provider_surface_id = 'eth0' } },
	}, { provider_id = 'cm5-local-wired' })
	assert_not_nil(d, err)
	assert_not_nil(d.backend)
	assert_eq(d.provider, nil)
	assert_eq(d.provider_name, 'static')
	assert_eq(d.provider_id, 'cm5-local-wired')
	assert_not_nil(d.snapshot_op)
end

function tests.test_wired_driver_requires_observe_groups_backend_contract()
	package.loaded['services.hal.backends.wired.providers.invalid_missing_observe_groups'] = {
		new = function ()
			return {
				snapshot_op = function () end,
				watch_op = function () end,
				apply_attachments_op = function () end,
				set_poe_op = function () end,
				bounce_op = function () end,
				terminate = function () end,
			}
		end,
	}
	local driver_mod = require 'services.hal.drivers.wired'
	local d, err = driver_mod.new({ provider = 'invalid_missing_observe_groups' }, { provider_id = 'bad' })
	assert_eq(d, nil)
	assert_true(type(err) == 'string' and err:find('observe_groups_op', 1, true) ~= nil, tostring(err))
	package.loaded['services.hal.backends.wired.providers.invalid_missing_observe_groups'] = nil
end

function tests.test_rtl8380m_observe_groups_deduplicates_shared_commands()
	local commands, err = provider._test.commands_for_groups({ 'panel', 'poe', 'counters' })
	assert_not_nil(commands, err)
	local seen = {}
	for _, cmd in ipairs(commands) do
		assert_eq(seen[cmd], nil, 'duplicate command ' .. tostring(cmd))
		seen[cmd] = true
	end
	assert_true(seen.home_main == true, 'home_main should be included once')
	assert_true(seen.panel_info == true, 'panel_info should be included')
	assert_true(seen.poe_poe == true, 'poe_poe should be included')
	assert_true(seen.rmon_statistics == true, 'rmon_statistics should be included')
end

function tests.test_wired_manager_requires_canonical_poll_table()
	local manager = require 'services.hal.managers.wired'
	local plan, err = manager._test.provider_poll_plan({})
	assert_eq(plan, nil)
	assert_true(type(err) == 'string' and err:find('poll is required', 1, true) ~= nil, tostring(err))

	plan, err = manager._test.provider_poll_plan({ poll_interval_s = 0.5 })
	assert_eq(plan, nil)
	assert_true(type(err) == 'string' and err:find('poll_interval_s', 1, true) ~= nil, tostring(err))

	plan, err = manager._test.provider_poll_plan({
		poll = {
			static = { interval_s = 30.0, groups = { 'snapshot' } },
		},
	})
	assert_not_nil(plan, err)
	assert_eq(#plan, 1)
	assert_eq(plan[1].name, 'static')
	assert_eq(plan[1].interval_s, 30.0)
	assert_eq(plan[1].groups[1], 'snapshot')
end

return tests
