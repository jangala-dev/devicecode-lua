-- tests/unit/net/test_wan_runtime.lua

local fibers = require 'fibers'
local op = require 'fibers.op'
local mailbox = require 'fibers.mailbox'
local runfibers = require 'tests.support.run_fibers'

local wan_runtime = require 'services.net.wan_runtime'

local tests = {}

local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg) if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

function tests.test_speedtest_service_timeout_aborts_hal_bus_op_without_hidden_bus_timeout()
	runfibers.run(function(scope)
		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local seen_opts
		local aborted = false
		local hal = {
			speedtest_op = function (_, _request, opts)
				seen_opts = opts
				return op.never():on_abort(function () aborted = true end)
			end,
		}

		local handle, err = wan_runtime.start_speedtest({
			lifetime_scope = scope,
			done_tx = done_tx,
			hal = hal,
			generation = 1,
			speedtest_id = 7,
			uplink_id = 'wan_a',
			request = { interface = 'wan_a', max_duration_s = 0.01 },
		})
		ok(handle, err)
		local ev = fibers.perform(done_rx:recv_op())
		ok(ev and ev.kind == 'net_speedtest_done', 'speedtest completion expected')
		ok(aborted, 'timeout should abort the underlying HAL Op')
		ok(seen_opts and seen_opts.timeout == false, 'HAL bus call should not receive hidden positive timeout')
		ok(ev.result and ev.result.result and ev.result.result.timeout == true, 'timeout result expected')
		eq(ev.result.result.err, 'net_speedtest_timeout')
	end)
end

function tests.test_live_weights_service_timeout_aborts_hal_bus_op_without_hidden_bus_timeout()
	runfibers.run(function(scope)
		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local seen_opts
		local aborted = false
		local hal = {
			apply_live_weights_op = function (_, _request, opts)
				seen_opts = opts
				return op.never():on_abort(function () aborted = true end)
			end,
		}

		local handle, err = wan_runtime.start_live_weights({
			lifetime_scope = scope,
			done_tx = done_tx,
			hal = hal,
			generation = 1,
			weight_apply_id = 3,
			members = { { id = 'wan_a', interface = 'wan_a', weight = 1 } },
			timeout_s = 0.01,
		})
		ok(handle, err)
		local ev = fibers.perform(done_rx:recv_op())
		ok(ev and ev.kind == 'net_live_weights_done', 'live weights completion expected')
		ok(aborted, 'timeout should abort the underlying HAL Op')
		ok(seen_opts and seen_opts.timeout == false, 'HAL bus call should not receive hidden positive timeout')
		ok(ev.result and ev.result.result and ev.result.result.timeout == true, 'timeout result expected')
		eq(ev.result.result.err, 'net_live_weights_timeout')
	end)
end

return tests
