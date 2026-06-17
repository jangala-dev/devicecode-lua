local capdeps = require 'services.support.capdeps'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

function M.test_capability_dependency_returns_only_declared_methods()
	local calls = {}
	local sdk = {
		new_ref = function (conn, id)
			eq(conn, 'bus-conn')
			eq(id, 'main')
			return {
				status_op = function (_, opts) calls[#calls + 1] = { 'status', opts }; return 'status-result' end,
				exchange_op = function (_, args, opts) calls[#calls + 1] = { 'exchange', args, opts }; return 'exchange-result' end,
				listen_op = function () error('not narrowed', 0) end,
			}
		end,
	}
	local decl = ok(capdeps.capability({ sdk = sdk, default_cap_id = 'main', methods = { 'status_op', 'exchange_op' } }))
	local resolver = ok(capdeps.new('bus-conn', { http_client = decl }))
	local port = ok(resolver:get('http_client'))
	eq(type(port.status_op), 'function')
	eq(type(port.exchange_op), 'function')
	eq(port.listen_op, nil)
	eq(port.conn, nil)
	eq(port:status_op({ timeout = 1 }), 'status-result')
	eq(port:exchange_op({ uri = 'http://example.test/' }, { timeout = 2 }), 'exchange-result')
	eq(#calls, 2)
	eq(calls[1][1], 'status')
	eq(calls[2][1], 'exchange')
end

function M.test_dependency_factory_uses_requested_cap_id_and_caches_ports()
	local ids = {}
	local sdk = {
		new_ref = function (_, id)
			ids[#ids + 1] = id
			return { status_op = function () return id end }
		end,
	}
	local decl = ok(capdeps.capability({ sdk = sdk, default_cap_id = 'main', methods = { 'status_op' } }))
	local resolver = ok(capdeps.new('conn', { http_client = decl }))
	local factory = resolver:factory('http_client')
	local a = ok(factory('switch-http'))
	local b = ok(factory('switch-http'))
	local c = ok(factory())
	eq(a, b)
	eq(a:status_op(), 'switch-http')
	eq(c:status_op(), 'main')
	eq(#ids, 2)
end

function M.test_capability_dependency_rejects_undeclared_and_missing_methods()
	local decl = ok(capdeps.capability({
		sdk = { new_ref = function () return {} end },
		methods = { 'status_op' },
	}))
	local resolver = ok(capdeps.new('conn', { http_client = decl }))
	local port, err = resolver:get('missing')
	eq(port, nil)
	ok(tostring(err):find('undeclared dependency', 1, true))
	port, err = resolver:get('http_client')
	eq(port, nil)
	ok(tostring(err):find('missing method status_op', 1, true))
end

return M
