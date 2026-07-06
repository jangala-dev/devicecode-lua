-- tests/unit/net/test_wan_runtime.lua

local fibers = require 'fibers'
local op = require 'fibers.op'
local mailbox = require 'fibers.mailbox'
local runfibers = require 'tests.support.run_fibers'

local wan_runtime = require 'services.net.wan_runtime'
local wan_manager = require 'services.net.wan_manager'
local model_mod = require 'services.net.model'

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


function tests.test_reconcile_applies_live_weights_when_speedtests_are_fresh()
	runfibers.run(function(scope)
		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local applied
		local hal = {
			apply_live_weights_op = function(_, request)
				applied = request
				return op.always({ ok = true, changed = true, applied = true })
			end,
		}
		local model = model_mod.new('net-test')
		model:update(function(s)
			s.generation = 2
			s.wan = {
				load_balancing = { speedtests = true, policy = 'balanced' },
				members = {
					wan = { interface = 'wan', metric = 1 },
					modem = { interface = 'modem', metric = 1 },
				},
			}
			s.observed.snapshot = {
				multiwan = {
					interfaces_by_semantic = {
						wan = { interface = 'wan', state = 'online', online = true, usable = true },
						modem = { interface = 'modem', state = 'online', online = true, usable = true },
					},
				},
			}
			s.wan_runtime = {
				uplinks = {},
				speedtests = {
					wan = { state = 'done', generation = 1, ok = true, peak_mbps = 80, last_success_mbps = 80, completed_at = 10 },
					modem = { state = 'done', generation = 2, ok = true, peak_mbps = 20, last_success_mbps = 20, completed_at = 20 },
				},
				live_weights = {},
				last_weight_apply = { generation = 2, members = {
					{ id = 'wan', interface = 'wan', metric = 1, weight = 1, probe = true },
					{ id = 'modem', interface = 'modem', metric = 1, weight = 99, probe = false },
				} },
			}
			return s
		end)
		local state = {
			scope = scope,
			service_id = 'net-test',
			model = model,
			hal = hal,
			done_tx = done_tx,
			active_speedtests = {},
			active_weight_apply = nil,
			next_speedtest_id = 1,
			next_weight_apply_id = 1,
			current_generation = { generation = 2 },
			now = function() return 30 end,
		}
		local ok_apply, err = wan_manager.reconcile_speedtests(state, 'observed_state')
		ok(ok_apply, err)
		local ev = fibers.perform(done_rx:recv_op())
		ok(ev and ev.kind == 'net_live_weights_done', 'live weight apply completion expected')
		ok(applied and applied.members, 'live weight request expected')
		local by_id = {}
		for _, m in ipairs(applied.members) do by_id[m.id] = m end
		eq(by_id.wan.weight, 80)
		eq(by_id.modem.weight, 20)
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
