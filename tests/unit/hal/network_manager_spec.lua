-- tests/unit/hal/network_manager_spec.lua

local tests = {}

local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg) if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

function tests.test_network_manager_is_strict_op_only()
	local manager = require 'services.hal.managers.network'
	eq(manager.api_mode, 'op_only')
	ok(type(manager.start_op) == 'function', 'start_op required')
	ok(type(manager.apply_config_op) == 'function', 'apply_config_op required')
	ok(type(manager.shutdown_op) == 'function', 'shutdown_op required')
	ok(type(manager.terminate) == 'function', 'terminate required')
	ok(type(manager.fault_op) == 'function', 'fault_op required')
end

function tests.test_network_capability_constructors_exist()
	local caps = require 'services.hal.types.capabilities'
	ok(type(caps.new.NetworkConfigCapability) == 'function', 'network-config constructor required')
	ok(type(caps.new.NetworkStateCapability) == 'function', 'network-state constructor required')
	ok(type(caps.new.NetworkDiagnosticsCapability) == 'function', 'network-diagnostics constructor required')
end

function tests.test_network_backend_contract_requires_op_methods()
	local contract = require 'services.hal.backends.network.contract'
	local op = require 'fibers.op'
	local provider = {
		validate_op = function () return op.always({ ok = true }) end,
		plan_op = function () return op.always({ ok = true }) end,
		apply_op = function () return op.always({ ok = true }) end,
		snapshot_op = function () return op.always({ ok = true }) end,
		probe_link_op = function () return op.always({ ok = true }) end,
		read_counters_op = function () return op.always({ ok = true }) end,
		terminate = function () return true end,
	}
	local valid, err = contract.validate_provider(provider)
	ok(valid, err)

	provider.apply_op = nil
	valid, err = contract.validate_provider(provider)
	if valid ~= nil then error('provider without apply_op should be rejected', 2) end
	ok(err and err:find('apply_op', 1, true), 'apply_op error expected')
end

return tests
