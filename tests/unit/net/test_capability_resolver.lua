-- tests/unit/net/test_capability_resolver.lua

local busmod = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local resolver_mod = require 'services.net.capability_resolver'
local hal_client = require 'services.net.hal_client'

local tests = {}

local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg) if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

function tests.test_default_resolver_creates_curated_network_refs()
	runfibers.run(function()
		local b = busmod.new()
		local conn = b:connect()
		local r = ok(resolver_mod.open(conn, {}))
		local opts = r:client_opts()
		ok(opts.network_config_cap, 'network config ref expected')
		ok(opts.network_state_cap, 'network state ref expected')
		ok(opts.network_diagnostics_cap, 'network diagnostics ref expected')
		local client = hal_client.new(conn, opts)
		eq(client:available(), true)
		r:close()
	end)
end

function tests.test_resolver_can_disable_defaults_for_tests()
	runfibers.run(function()
		local b = busmod.new()
		local conn = b:connect()
		local r = ok(resolver_mod.open(conn, { resolve_defaults = false }))
		local opts = r:client_opts()
		eq(opts.network_config_cap, nil)
		eq(opts.network_state_cap, nil)
		eq(opts.network_diagnostics_cap, nil)
		r:close()
	end)
end

return tests
