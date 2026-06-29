-- tests/unit/device/test_phase2.lua

local fibers = require 'fibers'
local op = require 'fibers.op'
local cond = require 'fibers.cond'
local mailbox = require 'fibers.mailbox'
local sleep = require 'fibers.sleep'

local config = require 'services.device.config'
local catalogue = require 'services.device.catalogue'
local model_mod = require 'services.device.model'
local service = require 'services.device.service'
local action_worker = require 'services.device.action_worker'
local observer = require 'services.device.observer'
local topics = require 'services.device.topics'
local projection = require 'services.device.projection'
local component_mcu = require 'services.device.component_mcu'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_false(v, msg) if v ~= false then fail(msg or ('expected false, got ' .. tostring(v))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function wait_for_signal(c, msg)
	local which = fibers.perform(fibers.named_choice{
		ready = c:wait_op(),
		timeout = sleep.sleep_op(1),
	})
	assert_eq(which, 'ready', msg or 'timed out waiting for test barrier')
end

local function req(payload)
	local r = { payload = payload, replied = nil, failed = nil }
	function r:reply(v) self.replied = v; return true end
	function r:fail(e) self.failed = e; return true end
	return r
end


local function take_stage_source(params, expected)
	assert_not_nil(params and params.source_owner, 'source_owner required')
	local source = params.source_owner:value()
	if expected ~= nil then assert_eq(source, expected) end
	local detached, err = params.source_owner:detach()
	assert_eq(detached, source, tostring(err))
	return source
end

local function sample_config(display_name)
	return {
		schema = config.SCHEMA,
		components = {
			mcu = {
				subtype = 'mcu',
				display = { name = display_name or 'MCU' },
				facts = { software = topics.raw_member_state('mcu', 'software') },
				actions = { restart = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') } },
			},
		},
	}
end


function tests.test_default_fabric_client_disables_bus_timeout_but_passes_transfer_budget()
	local seen_topic, seen_payload, seen_opts

	fibers.run(function ()
		local conn = {
			call_op = function (_, topic, payload, opts)
				seen_topic = topic
				seen_payload = payload
				seen_opts = opts
				return op.always({ ok = true, result = { accepted = true } })
			end,
		}
		local client = assert(service.default_fabric_client(conn))
		local result, err = fibers.perform(client:send_blob_op({
			request_id = 'r-fabric-stage',
			target = 'updater/main',
			chunk_size = 2048,
			timeout = 300,
		}, {}))
		assert_nil(err)
		assert_true(result.accepted)
	end)

	assert_eq(table.concat(seen_topic, '/'), 'cap/transfer-manager/main/rpc/send-blob')
	assert_eq(seen_payload.timeout_s, 300)
	assert_eq(seen_payload.target, 'updater/main')
	assert_eq(seen_opts.timeout, false, 'Device must not hide a lua-bus timeout inside Fabric staging')
end

function tests.test_default_catalogue_includes_host_and_mcu_components()
	local cat = catalogue.build(nil)
	assert_not_nil(cat.components.cm5)
	assert_not_nil(cat.components.mcu)
	assert_not_nil(cat.components.mcu.facts.software)
	assert_not_nil(cat.components.mcu.events.charger_alert)
	assert_not_nil(cat.components.mcu.actions.restart)
end

function tests.test_public_metadata_config_change_does_not_restart_generation_but_updates_model()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = nil,
			enable_actions = false,
			enable_observers = false,
		})

		local ok, err = service.apply_config_payload(state, sample_config('A'))
		assert_true(ok, err)
		local generation = state.active.generation
		assert_eq(state.model:snapshot().components.mcu.display.name, 'A')

		ok, err = service.apply_config_payload(state, sample_config('B'))
		assert_true(ok, err)
		assert_eq(state.active.generation, generation)
		assert_eq(state.model:snapshot().components.mcu.display.name, 'B')
		assert_true(state.dirty.components.mcu)
	end)
end

function tests.test_next_event_prioritises_config_before_ready_action_request()
	fibers.run(function (scope)
		local config_tx, config_rx = mailbox.new(2, { full = 'reject_newest' })
		local action_tx, action_rx = mailbox.new(2, { full = 'reject_newest' })
		local state = service.build_state(scope, {
			conn = nil,
			config_rx = config_rx,
			enable_actions = false,
			enable_observers = false,
		})

		state.active = {
			generation = 7,
			action_eps = {
				['mcu:restart'] = {
					key = 'mcu:restart',
					generation = 7,
					component = 'mcu',
					action = 'restart',
					ep = { recv_op = function () return action_rx:recv_op() end },
				},
			},
		}

		fibers.perform(action_tx:send_op(req()))
		fibers.perform(config_tx:send_op({ kind = 'config_changed', payload = sample_config('prio') }))

		local ev = fibers.perform(service.next_event_op(state))
		assert_eq(ev.kind, 'config_changed')
		assert_eq(ev.payload.components.mcu.display.name, 'prio')
	end)
end


function tests.test_fabric_stage_source_owner_transfer_does_not_terminate_source_in_action_scope()
	local terminate_count = 0
	fibers.run(function (scope)
		local source = { id = 'src' }
		local r = req({ source = source })
		local client = {
			send_blob_op = function (_, params)
				take_stage_source(params, source)
				assert_eq(params.component, 'mcu')
				assert_eq(params.target, 'updater/main')
				return op.always({ ok = true, staged = true })
			end,
		}

		local result = action_worker.run(scope, {
			request = r,
			component_id = 'mcu',
			action = 'stage-update',
			request_id = 'r1',
			action_spec = { kind = 'fabric_stage', target = 'updater/main' },
			fabric_client = client,
			terminate_source = function () terminate_count = terminate_count + 1; return true end,
		})

		assert_true(result.ok)
		assert_not_nil(r.replied)
	end)
	assert_eq(terminate_count, 0)
end


function tests.test_fabric_stage_requires_client_to_take_source_ownership()
	local terminate_count = 0
	fibers.run(function (scope)
		local source = { id = 'src-no-proof' }
		local r = req({ source = source })
		local client = {
			send_blob_op = function ()
				return op.always({ ok = true, staged = true })
			end,
		}

		local result = action_worker.run(scope, {
			request = r,
			component_id = 'mcu',
			action = 'stage-update',
			request_id = 'r-no-proof',
			action_spec = { kind = 'fabric_stage', target = 'updater/main' },
			fabric_client = client,
			terminate_source = function (v)
				assert_eq(v, source)
				terminate_count = terminate_count + 1
				return true
			end,
		})

		assert_eq(result.ok, false)
		assert_eq(r.failed, 'fabric_stage client did not take source ownership')
	end)
	assert_eq(terminate_count, 1)
end


function tests.test_fabric_stage_failed_admission_terminates_untransferred_source()
	local terminate_count = 0
	fibers.run(function (scope)
		local source = { id = 'src' }
		local r = req({ source = source })
		local client = {
			send_blob_op = function () return op.always(nil, 'no_route') end,
		}

		local result = action_worker.run(scope, {
			request = r,
			component_id = 'mcu',
			action = 'stage-update',
			request_id = 'r2',
			action_spec = { kind = 'fabric_stage', target = 'updater/main' },
			fabric_client = client,
			terminate_source = function (v, reason)
				assert_eq(v, source)
				assert_eq(reason, 'ok')
				terminate_count = terminate_count + 1
				return true
			end,
		})

		assert_eq(result.ok, false)
		assert_eq(r.failed, 'no_route')
	end)
	assert_eq(terminate_count, 1)
end

function tests.test_repeated_observation_does_not_change_model_version()
	fibers.run(function ()
		local cat = assert(config.to_catalogue(sample_config('A')))
		local m = model_mod.new()
		m:apply_catalogue(1, cat)
		local changed = m:apply_observation(1, {
			component = 'mcu', tag = 'fact_retained', fact = 'software', payload = { version = '1.0' },
		})
		assert_true(changed)
		local seen = m:version()
		changed = m:apply_observation(1, {
			component = 'mcu', tag = 'fact_retained', fact = 'software', payload = { version = '1.0' },
		})
		assert_eq(changed, false)
		assert_eq(m:version(), seen)
	end)
end

local function fake_bound_conn()
	local c = { bound = {}, events = {} }
	function c:bind(topic, opts)
		local k = table.concat(topic, '/')
		if self.bound[k] then
			error('already bound: ' .. k)
		end
		local ep = { topic = topic, key = k }
		self.bound[k] = ep
		self.events[#self.events + 1] = 'bind:' .. k
		function ep:recv_op()
			return mailbox.new(0, { full = 'reject_newest' })
		end
		return ep
	end
	function c:unbind(ep)
		local k = ep and ep.key or (ep and ep.topic and table.concat(ep.topic, '/') or tostring(ep))
		self.events[#self.events + 1] = 'unbind:' .. k
		self.bound[k] = nil
		return true
	end
	function c:retain() return true end
	function c:unretain() return true end
	function c:publish() return true end
	return c
end

function tests.test_generation_replacement_unbinds_old_endpoints_before_rebinding()
	fibers.run(function (scope)
		local conn = fake_bound_conn()
		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = true,
			enable_observers = false,
		})

		assert_true(service.apply_config_payload(state, sample_config('A')))
		assert_not_nil(next(conn.bound))

		local cfg2 = sample_config('B')
		cfg2.components.host = {
			class = 'host',
			subtype = 'cm5',
			facts = { software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software') },
		}

		local ok, err = service.apply_config_payload(state, cfg2)
		assert_true(ok, err)
		assert_eq(state.active.generation, 2)
		-- The same mcu public endpoints are now rebound for generation 2, which
		-- would have failed if generation 1 endpoints were left installed.
		assert_not_nil(conn.bound['cap/component/mcu/rpc/restart'])
	end)
end

function tests.test_action_timeout_cancels_action_scope_and_finalises_request()
	fibers.run(function ()
		local r = req()
		local conn = {
			call_op = function ()
				return sleep.sleep_op(60):wrap(function ()
					return { ok = true }
				end)
			end,
		}

		local st, _rep, primary = fibers.run_scope(function (scope)
			action_worker.run(scope, {
				conn = conn,
				request = r,
				component_id = 'mcu',
				action = 'restart',
				request_id = 'timeout-1',
				timeout = 0.02,
				action_spec = { call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') },
			})
		end)

		assert_eq(st, 'cancelled')
		assert_eq(primary, 'timeout')
		assert_eq(r.failed, 'timeout')
		assert_nil(r.replied)
	end)
end

function tests.test_remote_action_failure_is_public_result_not_worker_failure()
	fibers.run(function (scope)
		local r = req()
		local conn = {
			call_op = function ()
				return op.always({ ok = false, reason = 'remote_no' })
			end,
		}

		local result = action_worker.run(scope, {
			conn = conn,
			request = r,
			component_id = 'mcu',
			action = 'restart',
			request_id = 'r-public-fail',
			timeout = 1,
			action_spec = { call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') },
		})

		assert_eq(result.ok, false)
		assert_eq(result.public_status, 'remote_failed')
		assert_eq(result.err, 'remote_no')
		assert_eq(r.failed, 'remote_no')
	end)
end


function tests.test_action_worker_requires_call_op_and_does_not_use_call_fallback()
	fibers.run(function (scope)
		local r = req()
		local called = false
		local conn = {
			call = function ()
				called = true
				return { ok = true }
			end,
		}

		local result = action_worker.run(scope, {
			conn = conn,
			request = r,
			component_id = 'mcu',
			action = 'restart',
			request_id = 'no-call-op',
			timeout = 1,
			action_spec = { call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') },
		})

		assert_eq(called, false)
		assert_eq(result.ok, false)
		assert_eq(result.public_status, 'unavailable')
		assert_eq(result.err, 'connection does not support call_op')
		assert_eq(r.failed, 'connection does not support call_op')
	end)
end

function tests.test_failed_generation_start_leaves_no_active_generation_and_rolls_back_endpoints()
	fibers.run(function (scope)
		local conn = fake_bound_conn()
		local bind_count = 0
		local parent_bind = conn.bind
		function conn:bind(topic, opts)
			bind_count = bind_count + 1
			if bind_count == 2 then
				error('synthetic bind failure')
			end
			return parent_bind(self, topic, opts)
		end

		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = true,
			enable_observers = false,
		})

		local ok, err = service.apply_config_payload(state, sample_config('fails'))
		assert_nil(ok)
		assert_not_nil(err)
		assert_nil(state.active)
		assert_nil(next(conn.bound))
	end)
end


function tests.test_generation_replacement_cancels_old_generation_without_generation_shell_completion()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = nil,
			enable_actions = false,
			enable_observers = false,
		})

		assert_true(service.apply_config_payload(state, sample_config('A')))
		assert_eq(state.active.generation, 1)

		local cfg2 = sample_config('B')
		cfg2.components.host = {
			class = 'host',
			subtype = 'cm5',
			facts = { software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software') },
		}

		assert_true(service.apply_config_payload(state, cfg2))
		assert_eq(state.active.generation, 2)

		local ev = fibers.perform(state.done_rx:recv_op():or_else(function ()
			return nil
		end))
		assert_nil(ev, 'generation lifetime should not report a synthetic generation_done event')
		assert_eq(state.active.generation, 2)
	end)
end


function tests.test_service_finaliser_cancels_generation_before_closing_reporting_queues()
	local order = {}

	fibers.run(function ()
		local st, _rep, primary = fibers.run_scope(function (scope)
			local state = service.build_state(scope, {
				conn = nil,
				enable_actions = false,
				enable_observers = false,
			})

			local close_done = state.done_tx.close
			function state.done_tx:close(reason)
				order[#order + 1] = 'done_close:' .. tostring(reason)
				return close_done(self, reason)
			end

			local close_obs = state.observation_tx.close
			function state.observation_tx:close(reason)
				order[#order + 1] = 'observation_close:' .. tostring(reason)
				return close_obs(self, reason)
			end

			state.active = {
				generation = 77,
				action_eps = {},
				cancel = function (reason)
					order[#order + 1] = 'generation_cancel:' .. tostring(reason)
					return true, nil
				end,
			}
		end)

		assert_eq(st, 'ok')
		assert_nil(primary)
	end)

	assert_eq(order[1], 'generation_cancel:ok')
	assert_eq(order[2], 'done_close:ok')
	assert_eq(order[3], 'observation_close:ok')
end

function tests.test_observer_finaliser_owns_opened_handles_before_source_down_emit_can_fail()
	local terminate_count = 0

	fibers.run(function ()
		local tx = mailbox.new(0, { full = 'reject_newest' })
		local conn = { opened = 0 }

		function conn:watch_retained(_topic, _opts)
			self.opened = self.opened + 1
			if self.opened == 1 then
				return { id = 'watch-1' }
			end
			return nil, 'synthetic_watch_failure'
		end

		function conn:unwatch_retained(watch)
			assert_eq(watch.id, 'watch-1')
			terminate_count = terminate_count + 1
			return true
		end

		local st, _rep, primary = fibers.run_scope(function (scope)
			observer.run(scope, {
				conn = conn,
				tx = tx,
				generation = 1,
				component_id = 'mcu',
				component = {
					facts = {
						alpha = { watch_topic = { 'raw', 'alpha' } },
						beta = { watch_topic = { 'raw', 'beta' } },
					},
				},
			})
		end)

		assert_eq(st, 'failed')
		assert_not_nil(primary)
	end)

	assert_eq(terminate_count, 1)
end

function tests.test_observer_done_records_outcome_and_forgets_live_handle()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = nil,
			enable_actions = false,
			enable_observers = false,
		})

		state.active = {
			generation = 3,
			observers = { mcu = { cancel = function () end } },
			observer_outcomes = {},
		}

		local ev = {
			kind = 'observer_done',
			generation = 3,
			component = 'mcu',
			status = 'ok',
			result = { reason = 'done' },
		}

		local ok, err = service.reduce_event(state, ev)
		assert_true(ok, err)
		assert_nil(state.active.observers.mcu)
		assert_eq(state.active.observer_outcomes.mcu, ev)
	end)
end

function tests.test_generation_cancellation_cascades_to_in_flight_action_and_finalises_request()
	fibers.run(function (scope)
		local request_done = cond.new()
		local call_entered = cond.new()
		local r = req()
		function r:reply(v)
			self.replied = v
			request_done:signal()
			return true
		end
		function r:fail(e)
			self.failed = e
			request_done:signal()
			return true
		end

		local conn = {
			call_op = function ()
				call_entered:signal()
				return sleep.sleep_op(60):wrap(function () return { ok = true } end)
			end,
		}

		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = false,
			enable_observers = false,
			action_timeout = 60,
		})

		assert_true(service.apply_config_payload(state, sample_config('A')))
		local active = state.active
		local ok, err = service.reduce_event(state, {
			kind = 'component_action_request',
			generation = active.generation,
			component = 'mcu',
			action = 'restart',
			request = r,
		})
		assert_true(ok, err)
		assert_not_nil(next(state.pending_actions))
		wait_for_signal(call_entered, 'action worker did not enter raw RPC call')

		ok, err = service.cancel_active_generation(state, 'catalogue_changed')
		assert_true(ok, err)
		wait_for_signal(request_done, 'action request was not finalised after generation cancellation')

		assert_eq(r.failed, 'catalogue_changed')
		assert_nil(r.replied)
	end)
end


function tests.test_fabric_stage_open_source_may_be_an_explicit_op()
	fibers.run(function (scope)
		local source = { id = 'src-op' }
		local r = req({})
		local client = {
			send_blob_op = function (_, params)
				take_stage_source(params, source)
				return op.always({ ok = true, staged = true })
			end,
		}

		local result = action_worker.run(scope, {
			request = r,
			component_id = 'mcu',
			action = 'stage-update',
			request_id = 'r-source-op',
			action_spec = { kind = 'fabric_stage', target = 'updater/main' },
			fabric_client = client,
			open_source_op = function ()
				return sleep.sleep_op(0.001):wrap(function ()
					return source, nil
				end)
			end,
			terminate_source = function ()
				fail('source should have been handed off, not terminated')
			end,
		})

		assert_true(result.ok)
		assert_not_nil(r.replied)
	end)
end


function tests.test_fabric_stage_timeout_cancels_child_stage_and_terminates_unhanded_source()
	local terminate_count = 0

	fibers.run(function ()
		local source = { id = 'slow-source' }
		local r = req({ source = source })
		local client = {
			send_blob_op = function ()
				return sleep.sleep_op(60):wrap(function ()
					return { ok = true }
				end)
			end,
		}

		local st, _rep, primary = fibers.run_scope(function (scope)
			action_worker.run(scope, {
				request = r,
				component_id = 'mcu',
				action = 'stage-update',
				request_id = 'fabric-timeout',
				timeout = 0.02,
				action_spec = { kind = 'fabric_stage', target = 'updater/main' },
				fabric_client = client,
				terminate_source = function (v, reason)
					assert_eq(v, source)
					assert_eq(reason, 'timeout')
					terminate_count = terminate_count + 1
					return true
				end,
			})
		end)

		assert_eq(st, 'cancelled')
		assert_eq(primary, 'timeout')
		assert_eq(r.failed, 'timeout')
	end)

	assert_eq(terminate_count, 1)
end

function tests.test_completion_queue_admission_failure_fails_observing_scope()
	fibers.run(function ()
		local st, _rep, primary = fibers.run_scope(function (scope)
			local r = req()
			local conn = {
				call_op = function ()
					return op.always({ ok = true, value = 'ok' })
				end,
			}

			local state = service.build_state(scope, {
				conn = conn,
				done_queue_len = 0,
				enable_actions = false,
				enable_observers = false,
				action_timeout = 60,
			})

			assert_true(service.apply_config_payload(state, sample_config('A')))
			local ok, err = service.reduce_event(state, {
				kind = 'component_action_request',
				generation = state.active.generation,
				component = 'mcu',
				action = 'restart',
				request = r,
			})
			assert_true(ok, err)

			-- The action result is produced immediately, but the completion cannot
			-- be admitted to a zero-capacity done queue without a receiver.  The
			-- reporter must fail the observing scope rather than silently dropping it.
		end)

		assert_eq(st, 'failed')
		assert_not_nil(primary)
		assert_true(tostring(primary):find('device_action_done_report_failed', 1, true) ~= nil,
			'expected completion report failure, got ' .. tostring(primary))
	end)
end


function tests.test_generation_cancellation_cascades_into_fabric_stage_child_scope()
	local terminate_count = 0

	fibers.run(function (scope)
		local source = { id = 'gen-cancel-source' }
		local entered_stage = cond.new()
		local request_done = cond.new()
		local r = req({ source = source })
		function r:reply(v)
			self.replied = v
			request_done:signal()
			return true
		end
		function r:fail(e)
			self.failed = e
			request_done:signal()
			return true
		end

		local client = {
			send_blob_op = function ()
				-- The Fabric client is called only after the stage scope has acquired
				-- the source and installed its stage-scope cleanup finaliser.
				entered_stage:signal()
				return sleep.sleep_op(60):wrap(function ()
					return { ok = true }
				end)
			end,
		}

		local cfg = sample_config('A')
		cfg.components.mcu.actions['stage-update'] = {
			kind = 'fabric_stage',
			target = 'updater/main',
		}

		local state = service.build_state(scope, {
			conn = nil,
			enable_actions = false,
			enable_observers = false,
			action_timeout = 60,
			fabric_client = client,
			terminate_source = function (v, reason)
				assert_eq(v, source)
				assert_eq(reason, 'catalogue_changed')
				terminate_count = terminate_count + 1
				return true
			end,
		})

		assert_true(service.apply_config_payload(state, cfg))
		local generation = state.active.generation
		local ok, err = service.reduce_event(state, {
			kind = 'component_action_request',
			generation = generation,
			component = 'mcu',
			action = 'stage-update',
			request = r,
		})
		assert_true(ok, err)
		wait_for_signal(entered_stage, 'fabric-stage child did not acquire the source')

		ok, err = service.cancel_active_generation(state, 'catalogue_changed')
		assert_true(ok, err)
		wait_for_signal(request_done, 'fabric-stage action request was not finalised after generation cancellation')

		assert_eq(r.failed, 'catalogue_changed')
		assert_nil(r.replied)
	end)

	assert_eq(terminate_count, 1)
end

local function fake_live_conn()
	local c = {
		retained = {}, published = {}, endpoints = {}, watches = {}, subs = {},
		unwatched = 0, unsubscribed = 0, unbound = 0,
		watch_opened = cond.new(), watch_closed = cond.new(), endpoint_bound = cond.new(),
	}

	local function make_feed(topic)
		local tx, rx = mailbox.new(8, { full = 'drop_oldest' })
		local f = { topic = topic, tx = tx, rx = rx, closed = false }
		function f:recv_op()
			return self.rx:recv_op()
		end
		function f:close(reason)
			if not self.closed then
				self.closed = true
				self.tx:close(reason or 'closed')
			end
			return true
		end
		return f
	end

	function c:watch_retained(topic, _opts)
		local f = make_feed(topic)
		self.watches[#self.watches + 1] = f
		self.watch_opened:signal()
		return f
	end

	function c:unwatch_retained(watch)
		self.unwatched = self.unwatched + 1
		if watch and watch.close then watch:close('unwatched') end
		self.watch_closed:signal()
		return true
	end

	function c:subscribe(topic, _opts)
		local f = make_feed(topic)
		self.subs[#self.subs + 1] = f
		return f
	end

	function c:unsubscribe(sub)
		self.unsubscribed = self.unsubscribed + 1
		if sub and sub.close then sub:close('unsubscribed') end
		return true
	end

	function c:bind(topic, _opts)
		local k = table.concat(topic, '/')
		if self.endpoints[k] then error('already bound: ' .. k) end
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local ep = { topic = topic, key = k, tx = tx, rx = rx, closed = false }
		function ep:recv_op()
			return self.rx:recv_op()
		end
		function ep:close(reason)
			if not self.closed then
				self.closed = true
				self.tx:close(reason or 'closed')
			end
			return true
		end
		self.endpoints[k] = ep
		self.endpoint_bound:signal()
		return ep
	end

	function c:unbind(ep)
		if ep then
			self.endpoints[ep.key] = nil
			if ep.close then ep:close('unbound') end
		end
		self.unbound = self.unbound + 1
		return true
	end

	function c:retain(topic, payload) self.retained[table.concat(topic, '/')] = payload; return true end
	function c:unretain(topic) self.retained[table.concat(topic, '/')] = nil; return true end
	function c:publish(topic, payload) self.published[#self.published + 1] = { topic = topic, payload = payload }; return true end
	return c
end

function tests.test_config_replacement_with_live_observer_terminates_raw_watch()
	fibers.run(function (scope)
		local conn = fake_live_conn()
		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = false,
			enable_observers = true,
		})

		assert_true(service.apply_config_payload(state, sample_config('A')))
		local first = state.active
		wait_for_signal(conn.watch_opened, 'observer did not open a real-ish retained watch')
		assert_not_nil(conn.watches[1])

		local cfg2 = sample_config('B')
		cfg2.components.host = {
			class = 'host',
			subtype = 'cm5',
			facts = { software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software') },
		}
		assert_true(service.apply_config_payload(state, cfg2))
		assert_eq(first.scope:status(), 'cancelled')
		wait_for_signal(conn.watch_closed, 'old-generation observer did not release its retained watch')
		assert_true(conn.unwatched >= 1)

		-- The replacement generation also owns a live observer.  End the test by
		-- cancelling it explicitly; otherwise fibers.run() will correctly wait for
		-- that still-live child scope during structural join.
		assert_true(service.cancel_active_generation(state, 'test_done'))
	end)
end


function tests.test_config_replacement_with_live_fabric_stage_endpoint_cancels_action_and_terminates_source()
	local terminate_count = 0
	fibers.run(function (scope)
		local conn = fake_live_conn()
		local entered_stage = cond.new()
		local request_done = cond.new()
		local source = { id = 'live-endpoint-source' }
		local r = req({ source = source })
		function r:reply(v)
			self.replied = v
			request_done:signal()
			return true
		end
		function r:fail(e)
			self.failed = e
			request_done:signal()
			return true
		end

		local client = {
			send_blob_op = function ()
				entered_stage:signal()
				return sleep.sleep_op(60):wrap(function ()
					return { ok = true }
				end)
			end,
		}

		local cfg = sample_config('A')
		cfg.components.mcu.actions['stage-update'] = {
			kind = 'fabric_stage',
			target = 'updater/main',
		}

		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = true,
			enable_observers = false,
			auto_publish = false,
			action_timeout = 60,
			fabric_client = client,
			terminate_source = function (v, reason)
				assert_eq(v, source)
				assert_eq(reason, 'catalogue_changed')
				terminate_count = terminate_count + 1
				return true
			end,
		})

		assert_true(service.apply_config_payload(state, cfg))
		local ep = conn.endpoints['cap/component/mcu/rpc/stage-update']
		assert_not_nil(ep, 'stage-update endpoint was not bound')
		assert_true(fibers.perform(ep.tx:send_op(r)))

		local ev = fibers.perform(service.next_event_op(state))
		assert_eq(ev.kind, 'component_action_request')
		assert_true(service.reduce_event(state, ev))
		wait_for_signal(entered_stage, 'fabric-stage action did not start from endpoint request')

		local cfg2 = sample_config('B')
		cfg2.components.host = {
			class = 'host',
			subtype = 'cm5',
			facts = { software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software') },
		}
		assert_true(service.apply_config_payload(state, cfg2))
		wait_for_signal(request_done, 'live endpoint fabric-stage request was not finalised')
		assert_eq(r.failed, 'catalogue_changed')
		assert_nil(r.replied)
	end)
	assert_eq(terminate_count, 1)
end

function tests.test_action_start_cancelled_before_worker_body_resolves_request_without_calling_hal()
	fibers.run(function (scope)
		local called = false
		local r = req()
		local conn = {
			call_op = function ()
				called = true
				return op.always({ ok = true })
			end,
		}
		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = false,
			enable_observers = false,
			action_timeout = 60,
		})
		assert_true(service.apply_config_payload(state, sample_config('A')))
		local generation = state.active.generation
		assert_true(service.reduce_event(state, {
			kind = 'component_action_request',
			generation = generation,
			component = 'mcu',
			action = 'restart',
			request = r,
		}))

		-- No yield has happened since admission, so the worker body has not had an
		-- opportunity to call the HAL.  The setup-installed request owner still lets
		-- generation cancellation resolve the request immediately.
		assert_true(service.cancel_active_generation(state, 'catalogue_changed'))
		assert_eq(called, false)
		assert_eq(r.failed, 'catalogue_changed')
		assert_nil(r.replied)
	end)
end


function tests.test_fabric_stage_public_reply_is_sanitised_of_ownership_internals()
	fibers.run(function (scope)
		local source = { id = 'sanitize-source' }
		local r = req({ source = source })
		local client = {
			send_blob_op = function (_, params)
				take_stage_source(params, source)
				return op.always({ ok = true, transfer_id = 'tx1', source_owner = params.source_owner })
			end,
		}

		local result = action_worker.run(scope, {
			request = r,
			component_id = 'mcu',
			action = 'stage-update',
			request_id = 'sanitize',
			action_spec = { kind = 'fabric_stage', target = 'updater/main' },
			fabric_client = client,
			terminate_source = function () fail('source should be handed off') end,
		})

		assert_true(result.ok)
		assert_eq(r.replied.transfer_id, 'tx1')
		assert_nil(r.replied.source_owner)
		assert_nil(result.reply_payload.source_owner)
	end)
end

function tests.test_backpressure_policy_is_explicit()
	local backpressure = require 'services.device.backpressure'
	local p = backpressure.snapshot()
	assert_eq(p.completions.queue_full, 'fail_observing_scope')
	assert_eq(p.observations.queue_full, 'fail_observing_scope')
	assert_eq(p.action_endpoints.queue_full, 'reject_request')
	assert_eq(p.publication.policy, 'coalesce_dirty_state')
	assert_eq(p.publication.failure, 'fail_service')
	assert_eq(p.availability.source_down, 'mark_degraded_or_unavailable')
end

function tests.test_catalogue_entries_carry_component_modules()
	local cat = catalogue.build(nil)
	assert_eq(cat.components.mcu.module.kind, 'mcu')
	assert_eq(cat.components.cm5.module.kind, 'host')
end

function tests.test_mcu_fault_availability_is_stored_and_projected()
	fibers.run(function ()
		local cat = assert(config.to_catalogue({
			schema = config.SCHEMA,
			components = {
				mcu = {
					subtype = 'mcu',
					required_facts = { 'software', 'updater' },
					facts = {
						software = topics.raw_member_state('mcu', 'software'),
						updater = topics.raw_member_state('mcu', 'updater'),
						health = topics.raw_member_state('mcu', 'health'),
					},
				},
			},
		}))
		local m = model_mod.new()
		m:apply_catalogue(1, cat)
		m:apply_observation(1, { component = 'mcu', tag = 'fact_retained', fact = 'software', payload = { version = '1.0' } })
		m:apply_observation(1, { component = 'mcu', tag = 'fact_retained', fact = 'updater', payload = { state = 'idle' } })
		m:apply_observation(1, { component = 'mcu', tag = 'fact_retained', fact = 'health', payload = { state = 'failed' } })
		local rec = m:snapshot().components.mcu
		assert_eq(rec.status.availability, 'unavailable')
		assert_eq(rec.status.health, 'fault')
		local payloads = projection.component_payloads('mcu', rec, 10)
		assert_eq(payloads.component.availability, 'unavailable')
		assert_eq(payloads.cap_status.state, 'unavailable')
	end)
end

function tests.test_host_missing_software_degrades_rather_than_disappears()
	fibers.run(function ()
		local cat = assert(config.to_catalogue({
			schema = config.SCHEMA,
			components = {
				host = {
					class = 'host',
					subtype = 'cm5',
					required_facts = { 'software' },
					facts = {
						software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software'),
						updater = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'updater'),
					},
				},
			},
		}))
		local m = model_mod.new()
		m:apply_catalogue(1, cat)
		m:apply_observation(1, { component = 'host', tag = 'fact_retained', fact = 'updater', payload = { state = 'idle' } })
		local status = m:snapshot().components.host.status
		assert_eq(status.availability, 'degraded')
		assert_eq(status.reason, 'missing_host_software')
	end)
end

function tests.test_component_module_normalises_mcu_software_fact()
	local v, err = component_mcu.normalise_fact('software', { version = '2.3', build_id = 'abc' })
	assert_nil(err)
	assert_eq(v.version, '2.3')
	assert_eq(v.build_id, 'abc')
end

function tests.test_component_module_ignores_non_contract_mcu_fact_aliases()
	local software = assert(component_mcu.normalise_fact('software', { fw_version = 'legacy', build = 'legacy-build' }))
	assert_nil(software.version)
	assert_nil(software.build_id)

	local updater = assert(component_mcu.normalise_fact('updater', { status = 'available', err = 'boom' }))
	assert_nil(updater.state)
	assert_nil(updater.last_error)
end


function tests.test_stale_action_completion_is_archived_and_clears_pending_without_mutating_model()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = nil,
			enable_actions = false,
			enable_observers = false,
		})
		assert_true(service.apply_config_payload(state, sample_config('A')))
		local old_generation = state.active.generation
		state.pending_actions['old-action'] = {
			generation = old_generation,
			component = 'mcu',
			action = 'restart',
		}

		local cfg2 = sample_config('B')
		cfg2.components.host = {
			class = 'host',
			subtype = 'cm5',
			facts = { software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software') },
		}
		assert_true(service.apply_config_payload(state, cfg2))
		local current_generation = state.active.generation
		assert_true(current_generation ~= old_generation)

		local ok, err = service.reduce_event(state, {
			kind = 'component_action_done',
			generation = old_generation,
			component = 'mcu',
			action = 'restart',
			request_id = 'old-action',
			status = 'ok',
			result = { public_status = 'succeeded', ok = true },
		})
		assert_true(ok, err)
		assert_nil(state.pending_actions['old-action'])
		assert_not_nil(state.action_outcomes['old-action'])
		assert_not_nil(state.stale_action_outcomes['old-action'])
		assert_eq(state.action_outcomes['old-action'].current, false)
		assert_nil(state.model:snapshot().components.mcu.last_action,
			'stale action completion must not mutate current-generation model state')
	end)
end

function tests.test_stale_observer_completion_is_kept_on_generation_history()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = nil,
			enable_actions = false,
			enable_observers = false,
		})
		assert_true(service.apply_config_payload(state, sample_config('A')))
		local first = state.active
		first.observers.mcu = { cancel = function () return true end }

		local cfg2 = sample_config('B')
		cfg2.components.host = {
			class = 'host',
			subtype = 'cm5',
			facts = { software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software') },
		}
		assert_true(service.apply_config_payload(state, cfg2))

		local ev = {
			kind = 'observer_done',
			generation = first.generation,
			component = 'mcu',
			status = 'cancelled',
			primary = 'catalogue_changed',
		}
		local ok, err = service.reduce_event(state, ev)
		assert_true(ok, err)
		assert_nil(first.observers.mcu)
		assert_eq(first.observer_outcomes.mcu, ev)
		assert_eq(state.generation_history[first.generation].observer_outcomes.mcu, ev)
	end)
end

function tests.test_generation_cancel_marks_pending_actions_until_completion_arrives()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = nil,
			enable_actions = false,
			enable_observers = false,
		})
		assert_true(service.apply_config_payload(state, sample_config('A')))
		local gen = state.active.generation
		local cancelled = false
		state.pending_actions['pending'] = {
			generation = gen,
			component = 'mcu',
			action = 'restart',
			handle = {
				cancel = function (_, reason)
					cancelled = reason
					return true, nil
				end,
			},
		}

		assert_true(service.cancel_active_generation(state, 'catalogue_changed'))
		assert_eq(cancelled, 'catalogue_changed')
		assert_not_nil(state.pending_actions['pending'])
		assert_eq(state.pending_actions['pending'].cancelled, true)
		assert_eq(state.pending_actions['pending'].cancel_reason, 'catalogue_changed')

		assert_true(service.reduce_event(state, {
			kind = 'component_action_done',
			generation = gen,
			component = 'mcu',
			action = 'restart',
			request_id = 'pending',
			status = 'cancelled',
			primary = 'catalogue_changed',
		}))
		assert_nil(state.pending_actions['pending'])
		assert_not_nil(state.stale_action_outcomes['pending'])
	end)
end


function tests.test_mcu_charger_bitfields_are_expanded_in_device_projection()
	local raw = {
		vin_mV = 24153,
		vsys_mV = 24100,
		iin_mA = 623,
		state_bits = 0x0240,  -- absorb + cccv
		status_bits = 0x0005, -- iin_limit + const_voltage
		system_bits = 0x2045, -- enabled + ok_to_charge + vin_gt_vbat + intvcc_gt_2p8v
		seq = 7,
		uptime_ms = 1234,
	}
	local fact, err = component_mcu.normalise_fact('power_charger', raw)
	assert_nil(err)
	assert_eq(fact.vin_mV, 24153)
	assert_eq(fact.state_bits, raw.state_bits)
	assert_true(fact.state.absorb_charge)
	assert_true(fact.state.cccv_charge)
	assert_false(fact.state.bat_missing_fault)
	assert_true(fact.status.iin_limit_active)
	assert_true(fact.status.const_voltage)
	assert_false(fact.status.const_current)
	assert_true(fact.system.charger_enabled)
	assert_true(fact.system.ok_to_charge)
	assert_true(fact.system.vin_gt_vbat)
	assert_true(fact.system.intvcc_gt_2p8v)
end

return tests
