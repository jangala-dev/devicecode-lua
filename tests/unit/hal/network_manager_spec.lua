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
		watch_op = function () return op.always({ ok = true }) end,
		probe_link_op = function () return op.always({ ok = true }) end,
		read_counters_op = function () return op.always({ ok = true }) end,
		apply_live_weights_op = function () return op.always({ ok = true }) end,
		apply_shaping_op = function () return op.always({ ok = true }) end,
		speedtest_op = function () return op.always({ ok = true }) end,
		terminate = function () return true end,
	}
	local valid, err = contract.validate_provider(provider)
	ok(valid, err)

	provider.apply_op = nil
	valid, err = contract.validate_provider(provider)
	if valid ~= nil then error('provider without apply_op should be rejected', 2) end
	ok(err and err:find('apply_op', 1, true), 'apply_op error expected')
end

function tests.test_network_manager_cancels_driver_op_when_control_request_is_abandoned()
	local fibers = require 'fibers'
	local runtime = require 'fibers.runtime'
	local op = require 'fibers.op'
	local channel = require 'fibers.channel'
	local runfibers = require 'tests.support.run_fibers'
	local types = require 'services.hal.types.core'
	local manager = require 'services.hal.managers.network'
	local driver_mod = require 'services.hal.drivers.network'

	runfibers.run(function(scope)
		manager.terminate('test reset')
		local old_new = driver_mod.new
		scope:finally(function ()
			driver_mod.new = old_new
			manager.terminate('test cleanup')
		end)

		local entered = channel.new(1)
		local cancel_ch = channel.new(1)
		local aborted = false
		driver_mod.new = function ()
			return {
				speedtest_op = function ()
					fibers.perform(entered:put_op(true))
					return op.never():on_abort(function () aborted = true end)
				end,
				terminate = function () return true, nil end,
			}, nil
		end

		local dev_ev_ch = channel.new(4)
		local cap_emit_ch = channel.new(4)
		local ok_start, start_err = fibers.perform(manager.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(start_err))
		local dev_ev = fibers.perform(dev_ev_ch:get_op())
		local ok_apply, apply_err = fibers.perform(manager.apply_config_op({ provider = 'test' }))
		assert(ok_apply == true, tostring(apply_err))

		local diag_cap
		for _, cap in ipairs(dev_ev.capabilities or {}) do
			if cap.class == 'network-diagnostics' then diag_cap = cap end
		end
		assert(diag_cap and diag_cap.control_ch, 'network diagnostics cap expected')

		local reply_ch = channel.new(1)
		local cancel_op = cancel_ch:get_op():wrap(function (reason) return reason or 'caller_abandoned' end)
		local req = assert(types.new.ControlRequest('speedtest', { interface = 'wan_a' }, reply_ch, cancel_op))
		assert(fibers.perform(diag_cap.control_ch:put_op(req)) ~= false)
		assert(fibers.perform(entered:get_op()) == true)
		assert(fibers.perform(cancel_ch:put_op('caller_abandoned')) ~= false)

		for _ = 1, 4 do runtime.yield() end
		assert(aborted == true, 'driver op should be aborted after caller abandonment')
		local got = fibers.perform(reply_ch:get_op():or_else(function () return nil, 'not_ready' end))
		assert(got == nil, 'abandoned request should not receive a late reply')
	end)
end


function tests.test_network_apply_continues_after_caller_abandonment_once_admitted()
	local fibers = require 'fibers'
	local runtime = require 'fibers.runtime'
	local op = require 'fibers.op'
	local channel = require 'fibers.channel'
	local runfibers = require 'tests.support.run_fibers'
	local types = require 'services.hal.types.core'
	local manager = require 'services.hal.managers.network'
	local driver_mod = require 'services.hal.drivers.network'

	runfibers.run(function(scope)
		manager.terminate('test reset')
		local old_new = driver_mod.new
		scope:finally(function ()
			driver_mod.new = old_new
			manager.terminate('test cleanup')
		end)

		local entered = channel.new(1)
		local release = channel.new(1)
		local cancel_ch = channel.new(1)
		local aborted = false
		local completed = false
		driver_mod.new = function ()
			return {
				apply_op = function ()
					fibers.perform(entered:put_op(true))
					return release:get_op():wrap(function () completed = true; return { ok = true } end)
						:on_abort(function () aborted = true end)
				end,
				terminate = function () return true, nil end,
			}, nil
		end

		local dev_ev_ch = channel.new(4)
		local cap_emit_ch = channel.new(4)
		local ok_start, start_err = fibers.perform(manager.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(start_err))
		local dev_ev = fibers.perform(dev_ev_ch:get_op())
		local ok_apply, apply_err = fibers.perform(manager.apply_config_op({ provider = 'test' }))
		assert(ok_apply == true, tostring(apply_err))

		local cfg_cap
		for _, cap in ipairs(dev_ev.capabilities or {}) do
			if cap.class == 'network-config' then cfg_cap = cap end
		end
		assert(cfg_cap and cfg_cap.control_ch, 'network config cap expected')

		local reply_ch = channel.new(1)
		local cancel_op = cancel_ch:get_op():wrap(function (reason) return reason or 'caller_abandoned' end)
		local req = assert(types.new.ControlRequest('apply', { generation = 1 }, reply_ch, cancel_op))
		assert(fibers.perform(cfg_cap.control_ch:put_op(req)) ~= false)
		assert(fibers.perform(entered:get_op()) == true)
		assert(fibers.perform(cancel_ch:put_op('caller_abandoned')) ~= false)
		for _ = 1, 4 do runtime.yield() end
		assert(aborted == false, 'admitted network apply should not be aborted by caller abandonment')
		assert(fibers.perform(release:put_op(true)) ~= false)
		for _ = 1, 4 do runtime.yield() end
		assert(completed == true, 'network apply should drain after caller detaches')
		local got = fibers.perform(reply_ch:get_op():or_else(function () return nil, 'not_ready' end))
		assert(got == nil, 'detached caller should not receive a late reply')
	end)
end

return tests
