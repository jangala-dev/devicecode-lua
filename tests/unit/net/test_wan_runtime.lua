-- tests/unit/net/test_wan_runtime.lua

local fibers = require 'fibers'
local op = require 'fibers.op'
local mailbox = require 'fibers.mailbox'
local runfibers = require 'tests.support.run_fibers'

local wan_runtime = require 'services.net.wan_runtime'
local wan_manager = require 'services.net.wan_manager'
local model_mod = require 'services.net.model'
local active_uplink = require 'services.net.active_uplink'

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
			timeout_s = 0.01,
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


function tests.test_speedtest_allows_setup_time_beyond_payload_window()
	runfibers.run(function(scope)
		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local hal = {
			speedtest_op = function()
				return require('fibers.sleep').sleep_op(1.05):wrap(function()
					return {ok=true, mbps=12}
				end)
			end,
		}
		assert(wan_runtime.start_speedtest({
			lifetime_scope=scope, hal=hal, done_tx=done_tx,
			generation=1, speedtest_id=1, uplink_id='wan',
			request={interface='wan', max_duration_s=1},
		}))
		local ev = fibers.perform(done_rx:recv_op())
		assert(ev.result.result.ok and ev.result.result.mbps == 12)
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
				configured_members = {
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
			s.backhaul = {
				uplinks = {
					wan = { id = 'wan', interface = 'wan', state = 'online', usable = true, path_address = { family = 'ipv4', address = '203.0.113.10' } },
					modem = { id = 'modem', interface = 'modem', state = 'online', usable = true, path_address = { family = 'ipv4', address = '10.1.2.3' } },
				},
			}
			s.wan_runtime = {
				uplinks = {},
				speedtests = {
					wan = { state = 'done', generation = 1, ok = true, peak_mbps = 80, last_success_mbps = 80, completed_at = 10,
						measurement_key = 'v1|wan|wan||host-multiwan||ipv4|203.0.113.10|',
						last_success = { mbps = 80, completed_at = 10, measurement_key = 'v1|wan|wan||host-multiwan||ipv4|203.0.113.10|' } },
					modem = { state = 'done', generation = 2, ok = true, peak_mbps = 20, last_success_mbps = 20, completed_at = 20,
						measurement_key = 'v1|modem|modem||host-multiwan||ipv4|10.1.2.3|',
						last_success = { mbps = 20, completed_at = 20, measurement_key = 'v1|modem|modem||host-multiwan||ipv4|10.1.2.3|' } },
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

-- Strict failover relies on this: with speed tests off, live weights never
-- replace mwan3's metric-ordered policy chain, even with usable results.
function tests.test_reconcile_applies_no_live_weights_when_speedtests_are_disabled()
	runfibers.run(function(scope)
		local sleep = require 'fibers.sleep'
		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local wan_key = 'v1|wan|wan||host-multiwan||ipv4|203.0.113.10|'
		local modem_key = 'v1|modem|modem||host-multiwan||ipv4|10.1.2.3|'
		local applied = false
		local hal = {
			apply_live_weights_op = function()
				applied = true
				return op.always({ ok = true, changed = true, applied = true })
			end,
		}
		local model = model_mod.new('net-test')
		model:update(function(s)
			s.generation = 2
			s.wan = {
				load_balancing = { speedtests = { enabled = false }, policy = 'balanced' },
				configured_members = {
					wan = { interface = 'wan', metric = 1 },
					modem = { interface = 'modem', metric = 2 },
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
			s.backhaul = {
				uplinks = {
					wan = { id = 'wan', interface = 'wan', state = 'online', usable = true,
						path_address = { family = 'ipv4', address = '203.0.113.10' } },
					modem = { id = 'modem', interface = 'modem', state = 'online', usable = true,
						path_address = { family = 'ipv4', address = '10.1.2.3' } },
				},
			}
			s.wan_runtime = {
				uplinks = {},
				speedtests = {
					wan = { state = 'done', generation = 2, ok = true, peak_mbps = 80, last_success_mbps = 80,
						completed_at = 10, measurement_key = wan_key,
						last_success = { mbps = 80, completed_at = 10, measurement_key = wan_key } },
					modem = { state = 'done', generation = 2, ok = true, peak_mbps = 20, last_success_mbps = 20,
						completed_at = 20, measurement_key = modem_key,
						last_success = { mbps = 20, completed_at = 20, measurement_key = modem_key } },
				},
				live_weights = {},
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
		local which = fibers.perform(op.named_choice({
			done = done_rx:recv_op(),
			idle = sleep.sleep_op(0.05),
		}))
		eq(which, 'idle', 'no live weight work should start')
		eq(applied, false, 'live weights must not be applied')
		eq(state.next_speedtest_id, 1, 'no speed test should start')
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

function tests.test_interface_restart_reports_identity_and_passes_no_bus_timeout()
	runfibers.run(function(scope)
		local sleep = require 'fibers.sleep'
		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local seen_req, seen_opts
		local hal = {
			restart_interface_op = function (_, request, opts)
				seen_req, seen_opts = request, opts
				return sleep.sleep_op(0.05):wrap(function ()
					return { ok = true, backend = 'test', interface = request.interface }
				end)
			end,
		}

		local handle, err = wan_runtime.start_interface_restart({
			lifetime_scope = scope,
			done_tx = done_tx,
			hal = hal,
			interface = 'modem_primary',
			role = 'primary',
		})
		ok(handle, err)
		local ev = fibers.perform(done_rx:recv_op())
		eq(ev.kind, 'net_interface_restart_done')
		eq(ev.interface, 'modem_primary')
		eq(ev.role, 'primary')
		eq(seen_req.interface, 'modem_primary')
		ok(seen_opts and seen_opts.timeout == false, 'HAL bus call should not receive hidden positive timeout')
		eq(ev.result.ok, true)
	end)
end

local function check_running_speedtest_observations(missing_observation)
	runfibers.run(function(scope)
		local done_tx = mailbox.new(8, { full = 'reject_newest' })
		local model = model_mod.new('net-test')
		model:update(function(s)
			s.generation = 2
			s.wan = {
				load_balancing = { speedtests = true, policy = 'balanced' },
				configured_members = { wan = { interface = 'wan', metric = 1 } },
			}
			s.backhaul = { uplinks = { wan = {
				id = 'wan', interface = 'wan', state = 'online', usable = true,
				path_address = { family = 'ipv4', address = '203.0.113.10' },
			} } }
			s.wan_runtime = { uplinks = {}, live_weights = {}, speedtests = {
				wan = { state = 'running', generation = 2, id = 7 },
			} }
			return s
		end)
		local original = { generation = 2, speedtest_id = 7 }
		local state = {
			scope = scope, service_id = 'net-test', model = model,
			hal = { speedtest_op = function() return op.never() end },
			done_tx = done_tx, active_speedtests = { wan = original },
			current_generation = { generation = 2 }, next_speedtest_id = 8,
			now = function() return 100 end,
		}
		if missing_observation then
			model:update(function(s) s.backhaul.uplinks.wan.observed = false; return s end)
			assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
			model:update(function(s) s.backhaul.uplinks.wan.observed = true; return s end)
		end
		for _ = 1, 3 do
			assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		end
		eq(state.next_speedtest_id, 8, 'observations must not launch duplicate downloads')
		eq(state.active_speedtests.wan, original, 'original completion must remain current')
		eq(model:snapshot().wan_runtime.speedtests.wan.state, 'running')
		local accepted, reason = wan_manager.handle_speedtest_done(state, {
			uplink_id = 'wan', generation = 2, speedtest_id = 7,
			result = { ok = true, mbps = 12 },
		})
		ok(accepted and reason ~= 'stale', 'original completion must be accepted')
		eq(model:snapshot().wan_runtime.speedtests.wan.state, 'ok')
		eq(state.active_speedtests.wan, nil)
	end)
end

function tests.test_repeated_observations_preserve_running_speedtest()
	check_running_speedtest_observations(false)
end

function tests.test_missing_observation_preserves_running_speedtest()
	check_running_speedtest_observations(true)
end

function tests.test_due_speedtests_launch_one_at_a_time()
	runfibers.run(function(scope)
		local done_tx = mailbox.new(8, { full = 'reject_newest' })
		local model = model_mod.new('net-test')
		local ids = { 'wan', 'sim_a', 'sim_b' }
		model:update(function(s)
			s.generation = 2
			s.wan = { load_balancing = { speedtests = true, policy = 'balanced' }, configured_members = {} }
			s.backhaul = { uplinks = {} }
			for i, id in ipairs(ids) do
				s.wan.configured_members[id] = { interface = id, metric = 1 }
				s.backhaul.uplinks[id] = {
					id = id, interface = id, state = 'online', usable = true,
					path_address = { family = 'ipv4', address = '203.0.113.' .. i },
				}
			end
			s.wan_runtime = { uplinks = {}, live_weights = {}, speedtests = {} }
			return s
		end)
		local state = {
			scope = scope, service_id = 'net-test', model = model,
			hal = { speedtest_op = function() return op.never() end },
			done_tx = done_tx, active_speedtests = {},
			current_generation = { generation = 2 }, next_speedtest_id = 1,
			now = function() return 100 end,
		}
		for n = 1, #ids do
			assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
			assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
			eq(state.next_speedtest_id, n + 1, 'one launch per free slot')
			local uplink_id, active = next(state.active_speedtests)
			ok(active and next(state.active_speedtests, uplink_id) == nil, 'exactly one active speed test')
			assert(wan_manager.handle_speedtest_done(state, {
				uplink_id = uplink_id, generation = 2, speedtest_id = active.speedtest_id,
				result = { ok = true, mbps = 10 },
			}))
		end
		assert(wan_manager.reconcile_speedtests(state, 'speedtest_done'))
		eq(state.next_speedtest_id, #ids + 1, 'fresh results must not relaunch')
		for _, id in ipairs(ids) do eq(model:snapshot().wan_runtime.speedtests[id].state, 'ok') end
	end)
end

function tests.test_offline_uplink_releases_slot_for_due_uplink_in_same_reconcile()
	runfibers.run(function(scope)
		local done_tx = mailbox.new(8, { full = 'reject_newest' })
		local model = model_mod.new('net-test')
		model:update(function(s)
			s.generation = 2
			s.wan = {
				load_balancing = { speedtests = true, policy = 'balanced' },
				configured_members = { a = { interface = 'a', metric = 1 }, b = { interface = 'b', metric = 1 } },
			}
			s.backhaul = { uplinks = {
				a = { id = 'a', interface = 'a', state = 'online', usable = true,
					path_address = { family = 'ipv4', address = '203.0.113.1' } },
				b = { id = 'b', interface = 'b', state = 'offline', usable = false },
			} }
			s.wan_runtime = { uplinks = {}, live_weights = {}, speedtests = {
				b = { state = 'running', generation = 2, id = 7 },
			} }
			return s
		end)
		local cancelled
		local state = {
			scope = scope, service_id = 'net-test', model = model,
			hal = { speedtest_op = function() return op.never() end },
			done_tx = done_tx,
			active_speedtests = { b = { generation = 2, speedtest_id = 7,
				handle = { cancel = function(_, why) cancelled = why end } } },
			current_generation = { generation = 2 }, next_speedtest_id = 8,
			now = function() return 100 end,
		}
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		eq(cancelled, 'uplink_offline')
		eq(state.active_speedtests.b, nil)
		ok(state.active_speedtests.a, 'due uplink must launch once the offline test releases the slot')
		eq(state.next_speedtest_id, 9)
	end)
end

-- Active-scope speed tests: strict failover, test only the uplink carrying traffic.

local function active_scope_model(opts)
	opts = opts or {}
	local model = model_mod.new('net-test')
	model:update(function(s)
		s.generation = 2
		s.wan = {
			load_balancing = { policy = 'balanced', speedtests = {
				enabled = true, scope = 'active', interval_s = 21600,
				failover_retest_min_s = opts.failover_retest_min_s,
			} },
			last_resort = opts.last_resort,
			configured_members = {
				wan = { interface = 'wan', metric = 1 },
				modem_primary = { interface = 'modem_primary', metric = 2, source = { kind = 'gsm-uplink', id = 'primary' } },
			},
		}
		s.backhaul = { uplinks = {
			wan = { id = 'wan', interface = 'wan', state = 'online', usable = true, metric = 1,
				path_address = { family = 'ipv4', address = '203.0.113.10' } },
			modem_primary = { id = 'modem_primary', interface = 'modem_primary', state = 'online', usable = true, metric = 2,
				path_address = { family = 'ipv4', address = '10.1.2.3' } },
		} }
		s.backhaul.active_uplink = active_uplink.select(s, s.backhaul.uplinks)
		s.wan_runtime = { uplinks = {}, live_weights = {}, speedtests = {} }
		return s
	end)
	return model
end

local function set_online(model, online)
	model:update(function(s)
		for id, rec in pairs(s.backhaul.uplinks) do
			local up = online[id] == true
			rec.state = up and 'online' or 'offline'
			rec.usable = up
		end
		s.backhaul.active_uplink = active_uplink.select(s, s.backhaul.uplinks)
		return s
	end)
end

local function active_scope_state(scope, model, clock, extra)
	local state = {
		scope = scope, service_id = 'net-test', model = model,
		hal = {
			speedtest_op = function() return op.never() end,
			apply_live_weights_op = function()
				extra.weight_applies = (extra.weight_applies or 0) + 1
				return op.always({ ok = true, changed = true, applied = true })
			end,
		},
		done_tx = mailbox.new(8, { full = 'reject_newest' }),
		active_speedtests = {},
		current_generation = { generation = 2 }, next_speedtest_id = 1, next_weight_apply_id = 1,
		now = function() return clock.t end,
	}
	return state
end

local function only_active(state)
	local id, active = next(state.active_speedtests)
	ok(active and next(state.active_speedtests, id) == nil, 'exactly one active speed test')
	return id, active
end

local function finish(state, uplink_id, active, mbps)
	assert(wan_manager.handle_speedtest_done(state, {
		uplink_id = uplink_id, generation = 2, speedtest_id = active.speedtest_id,
		result = { ok = true, mbps = mbps or 10 },
	}))
end

function tests.test_active_scope_tests_only_the_active_uplink_and_never_changes_weights()
	runfibers.run(function(scope)
		local clock, extra = { t = 100 }, {}
		local model = active_scope_model()
		local state = active_scope_state(scope, model, clock, extra)
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		local id, active = only_active(state)
		eq(id, 'wan', 'wired WAN carries traffic under strict failover')
		local modem = model:snapshot().wan_runtime.speedtests.modem_primary
		eq(modem.state, 'skipped')
		eq(modem.last_skip_reason, 'not_active_uplink')

		finish(state, 'wan', active, 80)
		eq(state.active_weight_apply, nil, 'completion must not start a live weight apply')
		eq(model:snapshot().wan_runtime.live_weights.reason, 'speedtest_scope_active')
		assert(wan_manager.reconcile_speedtests(state, 'speedtest_done'))
		eq(state.active_weight_apply, nil)
		eq(state.next_speedtest_id, 2, 'standby modem must not be tested')
		eq(next(state.active_speedtests), nil)
		eq(extra.weight_applies, nil, 'active scope must never apply live weights')
		local runtime = model:snapshot().wan_runtime
		eq(runtime.last_weight_apply, nil)
		eq(runtime.live_weights.state, 'not_applicable')
		eq(runtime.live_weights.reason, 'speedtest_scope_active')
		eq(runtime.speedtests.wan.state, 'ok')
		eq(runtime.speedtests.wan.last_success_mbps, 80)
		eq(runtime.active_speedtest.uplink_id, 'wan')
	end)
end

function tests.test_active_scope_leaves_existing_weights_untouched()
	runfibers.run(function(scope)
		local clock, extra = { t = 100 }, {}
		local model = active_scope_model()
		local previous = { { id = 'wan', interface = 'wan', metric = 1, weight = 1 } }
		model:update(function(s) s.wan_runtime.last_weight_apply = { generation = 1, members = previous }; return s end)
		local state = active_scope_state(scope, model, clock, extra)
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		local id, active = only_active(state)
		finish(state, id, active, 50)
		eq(state.active_weight_apply, nil)
		assert(wan_manager.reconcile_speedtests(state, 'speedtest_done'))
		eq(state.active_weight_apply, nil)
		eq(extra.weight_applies, nil)
		local last = model:snapshot().wan_runtime.last_weight_apply
		eq(last.generation, 1)
		eq(#last.members, 1)
		eq(last.members[1].weight, 1)
	end)
end

function tests.test_active_scope_retests_after_failover_and_failback()
	runfibers.run(function(scope)
		local clock, extra = { t = 100 }, {}
		local model = active_scope_model()
		local state = active_scope_state(scope, model, clock, extra)
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		local id, active = only_active(state)
		eq(id, 'wan')
		finish(state, id, active, 80)

		-- WAN fails: mwan3 moves traffic to modem 1, which is tested.
		clock.t = 1000
		set_online(model, { modem_primary = true })
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		id, active = only_active(state)
		eq(id, 'modem_primary', 'failover must re-test on the new active uplink')
		finish(state, id, active, 20)

		-- WAN returns. Its earlier result is still within interval_s, but the
		-- path carrying traffic changed, so it is tested again.
		clock.t = 2000
		set_online(model, { wan = true, modem_primary = true })
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		id, active = only_active(state)
		eq(id, 'wan', 'failback must re-test the wired WAN')
		eq(model:snapshot().wan_runtime.active_speedtest.reason, 'active_uplink_changed')
		finish(state, id, active, 75)

		-- A second failover re-tests the modem even though its result is fresh.
		clock.t = 3000
		set_online(model, { modem_primary = true })
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		id = only_active(state)
		eq(id, 'modem_primary')
		eq(model:snapshot().wan_runtime.active_speedtest.reason, 'active_uplink_changed')
		eq(extra.weight_applies, nil)
	end)
end

function tests.test_active_scope_same_uplink_is_not_retested_before_interval()
	runfibers.run(function(scope)
		local clock, extra = { t = 100 }, {}
		local model = active_scope_model()
		local state = active_scope_state(scope, model, clock, extra)
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		local id, active = only_active(state)
		finish(state, id, active, 80)
		clock.t = 5000
		for _ = 1, 3 do assert(wan_manager.reconcile_speedtests(state, 'observed_state')) end
		eq(state.next_speedtest_id, 2, 'repeated observations must not re-test')
		clock.t = 100 + 21600 + 1
		assert(wan_manager.reconcile_speedtests(state, 'speedtest_retry_due'))
		id = only_active(state)
		eq(id, 'wan', 'interval_s expiry re-tests the active uplink')
	end)
end

function tests.test_active_scope_flapping_within_damping_window_does_not_retest()
	runfibers.run(function(scope)
		local clock, extra = { t = 100 }, {}
		local model = active_scope_model({ failover_retest_min_s = 300 })
		local state = active_scope_state(scope, model, clock, extra)
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		local id, active = only_active(state)
		finish(state, id, active, 80)

		clock.t = 150
		set_online(model, { modem_primary = true })
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		id, active = only_active(state)
		eq(id, 'modem_primary', 'never-tested modem is tested on first failover')
		finish(state, id, active, 20)

		clock.t = 200
		set_online(model, { wan = true, modem_primary = true })
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		eq(next(state.active_speedtests), nil, 'WAN tested 100 s ago is within the damping window')

		clock.t = 260
		set_online(model, { modem_primary = true })
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		eq(next(state.active_speedtests), nil, 'modem tested 110 s ago is within the damping window')
		eq(state.next_speedtest_id, 3)
		eq(model:snapshot().wan_runtime.active_speedtest.uplink_id, 'modem_primary')
	end)
end

function tests.test_active_scope_cancels_test_on_uplink_that_stopped_carrying_traffic()
	runfibers.run(function(scope)
		local clock, extra = { t = 100 }, {}
		local model = active_scope_model()
		model:update(function(s)
			s.wan_runtime.speedtests.modem_primary = { state = 'running', generation = 2, id = 7 }
			return s
		end)
		local state = active_scope_state(scope, model, clock, extra)
		local cancelled
		state.active_speedtests.modem_primary = { generation = 2, speedtest_id = 7,
			handle = { cancel = function(_, why) cancelled = why end } }
		state.next_speedtest_id = 8
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		eq(cancelled, 'not_active_uplink')
		local id = only_active(state)
		eq(id, 'wan', 'freed slot goes to the active uplink in the same reconcile')
		eq(model:snapshot().wan_runtime.speedtests.modem_primary.state, 'skipped')
	end)
end

function tests.test_active_scope_runs_nothing_without_an_active_uplink()
	for _, lr in ipairs({ 'default', 'unreachable' }) do
		runfibers.run(function(scope)
			local clock, extra = { t = 100 }, {}
			local model = active_scope_model({ last_resort = lr })
			set_online(model, {})
			local state = active_scope_state(scope, model, clock, extra)
			assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
			eq(next(state.active_speedtests), nil, 'no test without an active uplink (' .. lr .. ')')
			eq(state.next_speedtest_id, 1)
			eq(extra.weight_applies, nil)
			local runtime = model:snapshot().wan_runtime
			eq(runtime.live_weights.reason, 'speedtest_scope_active')
			eq(runtime.speedtests.wan.last_skip_reason, 'not_online')
		end)
	end
end

function tests.test_apply_keeps_active_scope_acknowledgement_for_current_members()
	local service = require 'services.net.service'
	local carry = service._test.carry_forward_wan_runtime
	local previous = {
		speedtests = { wan = { state = 'ok', last_success = { mbps = 80, completed_at = 10 } } },
		active_speedtest = { uplink_id = 'wan', reason = 'due', acknowledged_at = 10 },
	}
	local intent = { wan = { members = { wan = { interface = 'wan' }, modem_primary = { interface = 'modem_primary' } } } }
	local out = carry(previous, intent, 3)
	eq(out.active_speedtest.uplink_id, 'wan', 'failover after an apply must still be noticed')
	ok(out.active_speedtest ~= previous.active_speedtest, 'carried as a copy')

	out = carry(previous, { wan = { members = { modem_primary = { interface = 'modem_primary' } } } }, 4)
	eq(out.active_speedtest, nil, 'acknowledgement for a removed member is dropped')
end

function tests.test_active_scope_tests_the_active_member_when_ids_and_interfaces_collide()
	runfibers.run(function(scope)
		local clock, extra = { t = 100 }, {}
		local model = model_mod.new('net-test')
		model:update(function(s)
			s.generation = 2
			s.wan = {
				load_balancing = { speedtests = { enabled = true, scope = 'active' } },
				configured_members = {
					primary = { interface = 'wan', metric = 1 },
					wan = { interface = 'modem_primary', metric = 2 },
				},
			}
			s.backhaul = { uplinks = {
				primary = { id = 'primary', interface = 'wan', state = 'online', usable = true, metric = 1,
					path_address = { family = 'ipv4', address = '203.0.113.10' } },
				wan = { id = 'wan', interface = 'modem_primary', state = 'offline', usable = false, metric = 2 },
			} }
			s.backhaul.active_uplink = active_uplink.select(s, s.backhaul.uplinks)
			s.wan_runtime = { uplinks = {}, live_weights = {}, speedtests = {} }
			return s
		end)
		eq(model:snapshot().backhaul.active_uplink.uplink_id, 'primary')
		local state = active_scope_state(scope, model, clock, extra)
		assert(wan_manager.reconcile_speedtests(state, 'observed_state'))
		local id = only_active(state)
		eq(id, 'primary', 'the member carrying traffic must be tested')
	end)
end

return tests
