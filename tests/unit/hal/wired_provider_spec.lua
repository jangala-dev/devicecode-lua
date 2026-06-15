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
			['expansion-a'] = { provider = 'static', id = 'expansion-a' },
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

function tests.test_rtl8380m_http_stub_is_read_only()
	fibers.run(function ()
		local p = assert(provider.new({ id = 'switch-main' }))
		local snap = fibers.perform(p:snapshot_op({}))
		assert_true(snap.ok)
		assert_eq(snap.provider_id, 'switch-main')
		assert_true(snap.status.stub)
		local res = fibers.perform(p:apply_attachments_op({}))
		assert_eq(res.code, 'read_only')
		assert_not_nil(res.err)
	end)
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
		local p = assert(provider.new({ id = 'switch-main', base_url = 'http://192.168.1.1/', disable_login = true, http = { response_parser = 'legacy-http1-close' } }, { http_ref = http_ref }))
		local snap = fibers.perform(p:snapshot_op({}))
		assert_true(snap.ok, snap.status and snap.status.err)
		assert_eq(snap.surfaces.GE1.link.state, 'up')
		assert_eq(snap.surfaces.GE1.link.speed_mbps, 100)
		assert_eq(snap.surfaces.GE1.attachment.mode, 'trunk')
		assert_eq(snap.surfaces.GE1.attachment.accept_frame_type, 'all')
		assert_true(snap.surfaces.GE1.capabilities.poe)
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
			id = 'switch-main',
			base_url = 'http://192.168.1.1/',
			disable_login = true,
			http = { capability = 'switch-http', response_parser = 'legacy-http1-close' },
		}, {
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

return tests
