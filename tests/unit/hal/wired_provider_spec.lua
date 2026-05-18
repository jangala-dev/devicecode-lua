local fibers = require 'fibers'
local op = require 'fibers.op'
local provider = require 'services.hal.backends.wired.providers.rtl8380m_http'

local tests = {}
local function assert_true(v,msg) if v ~= true then error(msg or 'expected true',2) end end
local function assert_eq(a,b,msg)
	if a ~= b then error(msg or ('expected '..tostring(b)..', got '..tostring(a)),2) end
end
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

local function json_for_uri(uri)
	if uri:find('cmd=sys_sysTime', 1, true) then
		return '{"data":{"sysCurrTime":"2026-05-18 12:00:00"}}'
	elseif uri:find('cmd=sys_cpumem', 1, true) then
		return '{"data":{"cpu":12,"mem":34}}'
	elseif uri:find('cmd=panel_info', 1, true) then
		return '{"data":{"ports":[{"port":1,"link":"up","speed":"1000M","duplex":"full"}]}}'
	elseif uri:find('cmd=poe_poe', 1, true) then
		return '{"data":{"devPower":0,"devTemp":42,"ports":[{"port":1,"status":"off","power":0}]}}'
	end
	return '{"data":{}}'
end

local function fake_http_ref(calls)
	return {
		open_exchange_op = function (_, args)
			calls[#calls + 1] = args
			local exchange = {
				status = function () return '200' end,
				read_body_as_string_op = function () return op.always(json_for_uri(args.uri), nil) end,
				shutdown_op = function () return op.always(true, nil) end,
			}
			return op.always({ exchange = exchange }, nil)
		end,
	}
end

function tests.test_rtl8380m_http_provider_uses_http_ref_and_is_read_only()
	fibers.run(function ()
		local calls = {}
		local p = assert(provider.new({
			id = 'switch-main',
			http = { host = '192.0.2.10', cap_id = 'main' },
		}, {
			http_ref = fake_http_ref(calls),
		}))
		local snap = fibers.perform(p:snapshot_op({}))
		assert_true(snap.ok)
		assert_eq(snap.provider_id, 'switch-main')
		assert_eq(snap.status.driver, 'rtl8380m_http')
		assert_eq(snap.surfaces['port-1'].link.state, 'up')
		assert_eq(#calls, 4)
		assert_eq(calls[1].method, 'GET')
		assert_eq(calls[1].response_parser, 'tolerant-http1')
		assert_eq(calls[1].timeout_s, 10)
		local res = fibers.perform(p:apply_attachments_op({}))
		assert_eq(res.code, 'read_only')
		assert_not_nil(res.err)
	end)
end

function tests.test_rtl8380m_http_provider_accepts_narrow_http_ref_factory()
	fibers.run(function ()
		local calls = {}
		local requested_cap
		local p = assert(provider.new({
			id = 'switch-main',
			http = { host = '192.0.2.10', cap_id = 'switch-http' },
		}, {
			http_ref_for = function (cap_id)
				requested_cap = cap_id
				return fake_http_ref(calls)
			end,
		}))
		local snap = fibers.perform(p:snapshot_op({}))
		assert_true(snap.ok)
		assert_eq(requested_cap, 'switch-http')
		assert_eq(#calls, 4)
	end)
end

function tests.test_rtl8380m_http_provider_reports_unavailable_without_host()
	fibers.run(function ()
		local p = assert(provider.new({ id = 'switch-main' }))
		local snap = fibers.perform(p:snapshot_op({}))
		assert_eq(snap.ok, false)
		assert_eq(snap.status.state, 'unavailable')
		assert_eq(snap.status.code, 'host_not_configured')
	end)
end

return tests
