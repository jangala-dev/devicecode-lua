-- tests/services/fabric/test_link.lua

local fibers  = require 'fibers'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local protocol = require 'services.fabric.protocol'
local queue    = require 'devicecode.support.queue'

local link = require 'services.fabric.link'
local session = require 'services.fabric.session'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then
		fail(msg or ('expected true, got ' .. tostring(v)))
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		fail(msg or ('expected nil, got ' .. tostring(v)))
	end
end

local function assert_not_nil(v, msg)
	if v == nil then
		fail(msg or 'expected non-nil value')
	end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

local function assert_match(s, pat, msg)
	if type(s) ~= 'string' or not s:match(pat) then
		fail(msg or ('expected "' .. tostring(s) .. '" to match ' .. tostring(pat)))
	end
end


local function make_outbound_gate(outbound_tx)
	return session.new_outbound_gate {
		tx_control = outbound_tx,
		tx_rpc = outbound_tx,
		tx_bulk = outbound_tx,
	}
end

local function run_link_in_child(root_scope, params)
	return fibers.run_scope(function (scope)
		return link.run(scope, params)
	end)
end


-------------------------------------------------------------------------------
-- Session control establishes on hello and replies with hello_ack
-------------------------------------------------------------------------------

function tests.test_session_control_establishes_from_hello_and_sends_ack()
	fibers.run(function (scope)
		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local out_tx, out_rx = mailbox.new(8, { full = 'reject_newest' })
		local rpc_tx, _rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local transfer_tx, _transfer_rx = mailbox.new(8, { full = 'reject_newest' })
		local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local result = session.run(scope, {
				link_id = 'link-session',
				peer_id = 'peer-node',
				local_node = 'local-a',
				local_sid = 'local-sid',
				frame_rx = control_rx,
				tx_control = out_tx,
				outbound = make_outbound_gate(out_tx),
				rpc_tx = rpc_tx,
				transfer_tx = transfer_tx,
				hello_interval_s = 10,
				ping_interval_s = 10,
				liveness_timeout_s = 20,
			})
			queue.try_admit_required(done_tx, result, 'session_done')
		end)
		assert_true(ok, err)

		local initial = fibers.perform(out_rx:recv_op())
		assert_eq(initial.frame.type, 'hello')
		assert_eq(initial.frame.sid, 'local-sid')
		assert_eq(initial.frame.node, 'local-a')

		queue.try_admit_required(control_tx, {
			kind = 'frame_received',
			frame = assert(protocol.hello('peer-sid', 'peer-node')),
		}, 'remote_hello')

		local ack = fibers.perform(out_rx:recv_op())
		assert_eq(ack.frame.type, 'hello_ack')
		assert_eq(ack.frame.sid, 'local-sid')

		control_tx:close('test complete')

		local result = fibers.perform(done_rx:recv_op())
		assert_eq(result.role, 'session')
		assert_eq(result.snapshot.established, true)
		assert_eq(result.snapshot.peer_sid, 'peer-sid')
		assert_eq(result.snapshot.peer_node, 'peer-node')
		assert_eq(result.snapshot.link_generation, 1)
	end)
end

-------------------------------------------------------------------------------
-- Session liveness resets to hello after missing peer traffic
-------------------------------------------------------------------------------

function tests.test_session_liveness_timeout_resets_to_hello()
	fibers.run(function (scope)
		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local out_tx, out_rx = mailbox.new(8, { full = 'reject_newest' })
		local rpc_tx, session_event_rx = mailbox.new(8, { full = 'reject_newest' })
		local transfer_tx, transfer_event_rx = mailbox.new(8, { full = 'reject_newest' })
		local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local result = session.run(scope, {
				link_id = 'link-liveness',
				peer_id = 'peer-node',
				local_sid = 'local-sid',
				frame_rx = control_rx,
				tx_control = out_tx,
				outbound = make_outbound_gate(out_tx),
				rpc_tx = rpc_tx,
				transfer_tx = transfer_tx,

				-- This test is about the liveness reset, not ping emission.
				-- Keep ping safely beyond the liveness deadline so scheduler
				-- jitter cannot turn this into a ping/liveness ordering test.
				hello_interval_s = 10,
				ping_interval_s = 10,
				liveness_timeout_s = 0.02,
			})
			queue.try_admit_required(done_tx, result, 'session_done')
		end)
		assert_true(ok, err)

		assert_eq(fibers.perform(out_rx:recv_op()).frame.type, 'hello')
		queue.try_admit_required(control_tx, {
			kind = 'frame_received',
			frame = assert(protocol.hello('peer-sid', 'peer-node')),
		}, 'remote_hello')
		assert_eq(fibers.perform(out_rx:recv_op()).frame.type, 'hello_ack')

		local established = fibers.perform(session_event_rx:recv_op())
		assert_eq(established.kind, 'peer_session')
		assert_eq(established.session.peer_sid, 'peer-sid')
		local transfer_established = fibers.perform(transfer_event_rx:recv_op())
		assert_eq(transfer_established.kind, 'peer_session')
		assert_eq(transfer_established.session.peer_sid, 'peer-sid')

		local hello_after_timeout = fibers.perform(out_rx:recv_op())
		assert_eq(hello_after_timeout.frame.type, 'hello')
		assert_eq(hello_after_timeout.frame.sid == 'local-sid', false)

		local dropped = fibers.perform(session_event_rx:recv_op())
		assert_eq(dropped.kind, 'peer_session_dropped')
		assert_eq(dropped.session.peer_sid, 'peer-sid')
		assert_eq(dropped.reason, 'liveness_timeout')
		local transfer_dropped = fibers.perform(transfer_event_rx:recv_op())
		assert_eq(transfer_dropped.kind, 'peer_session_dropped')
		assert_eq(transfer_dropped.session.peer_sid, 'peer-sid')
		assert_eq(transfer_dropped.reason, 'liveness_timeout')

		control_tx:close('test complete')
		local result = fibers.perform(done_rx:recv_op())
		assert_eq(result.snapshot.established, false)
		assert_eq(result.snapshot.phase, 'hello')
		assert_eq(result.snapshot.why, 'liveness_timeout')
	end)
end

function tests.test_session_ping_is_emitted_before_liveness_deadline()
	fibers.run(function (scope)
		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local out_tx, out_rx = mailbox.new(8, { full = 'reject_newest' })
		local rpc_tx, session_event_rx = mailbox.new(8, { full = 'reject_newest' })
		local transfer_tx, transfer_event_rx = mailbox.new(8, { full = 'reject_newest' })
		local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local result = session.run(scope, {
				link_id = 'link-ping',
				peer_id = 'peer-node',
				local_sid = 'local-sid',
				frame_rx = control_rx,
				tx_control = out_tx,
				outbound = make_outbound_gate(out_tx),
				rpc_tx = rpc_tx,
				transfer_tx = transfer_tx,
				hello_interval_s = 10,
				ping_interval_s = 0.01,
				liveness_timeout_s = 1.0,
			})
			queue.try_admit_required(done_tx, result, 'session_done')
		end)
		assert_true(ok, err)

		assert_eq(fibers.perform(out_rx:recv_op()).frame.type, 'hello')
		queue.try_admit_required(control_tx, {
			kind = 'frame_received',
			frame = assert(protocol.hello('peer-sid', 'peer-node')),
		}, 'remote_hello')
		assert_eq(fibers.perform(out_rx:recv_op()).frame.type, 'hello_ack')

		local established = fibers.perform(session_event_rx:recv_op())
		assert_eq(established.kind, 'peer_session')
		local transfer_established = fibers.perform(transfer_event_rx:recv_op())
		assert_eq(transfer_established.kind, 'peer_session')

		local ping = fibers.perform(out_rx:recv_op())
		assert_eq(ping.frame.type, 'ping')
		assert_eq(ping.frame.sid, 'local-sid')

		control_tx:close('test complete')
		local result = fibers.perform(done_rx:recv_op())
		assert_eq(result.role, 'session')
	end)
end


function tests.test_session_control_processes_ready_control_before_timer_work()
	fibers.run(function (scope)
		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local out_tx, out_rx = mailbox.new(8, { full = 'reject_newest' })
		local rpc_tx, _rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local transfer_tx, _transfer_rx = mailbox.new(8, { full = 'reject_newest' })
		local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local result = session.run(scope, {
				link_id = 'link-control-before-timer',
				peer_id = 'peer-node',
				local_sid = 'local-sid',
				frame_rx = control_rx,
				tx_control = out_tx,
				outbound = make_outbound_gate(out_tx),
				rpc_tx = rpc_tx,
				transfer_tx = transfer_tx,
				hello_interval_s = 10,
				ping_interval_s = 10,
				liveness_timeout_s = 0.05,
			})
			queue.try_admit_required(done_tx, result, 'session_done')
		end)
		assert_true(ok, err)

		assert_eq(fibers.perform(out_rx:recv_op()).frame.type, 'hello')
		queue.try_admit_required(control_tx, {
			kind = 'frame_received',
			frame = assert(protocol.hello('peer-sid', 'peer-node')),
		}, 'remote_hello')
		assert_eq(fibers.perform(out_rx:recv_op()).frame.type, 'hello_ack')

		-- Move close to the original liveness deadline.  If the ready ping is not
		-- selected ahead of timer work, the session will reset when the old
		-- liveness deadline fires.  If the ping is processed first, the deadline is
		-- refreshed and the session should still be established at shutdown.
		fibers.perform(sleep.sleep_op(0.04))

		queue.try_admit_required(control_tx, {
			kind = 'frame_received',
			frame = assert(protocol.ping('peer-sid')),
		}, 'remote_ping')
		assert_eq(fibers.perform(out_rx:recv_op()).frame.type, 'pong')

		-- Let the previous liveness deadline pass; the refreshed deadline should
		-- still be in the future.
		fibers.perform(sleep.sleep_op(0.015))
		control_tx:close('test complete')
		local result = fibers.perform(done_rx:recv_op())
		assert_eq(result.snapshot.established, true)
		assert_eq(result.snapshot.peer_sid, 'peer-sid')
	end)
end

-------------------------------------------------------------------------------
-- Successful components complete the link
-------------------------------------------------------------------------------

function tests.test_successful_components_complete_link()
	fibers.run(function (root_scope)
		local st, rep, result = run_link_in_child(root_scope, {
			link_id = 'link-a',

			components = {
				{
					name = 'reader',
					run = function ()
						return {
							role = 'reader',
						}
					end,
				},

				{
					name = 'writer',
					run = function ()
						return {
							role = 'writer',
						}
					end,
				},
			},
		})

		assert_eq(st, 'ok')
		assert_eq(#rep.extra_errors, 0)
		assert_not_nil(result)

		local snap = result.snapshot

		assert_eq(snap.link_id, 'link-a')
		assert_eq(snap.state, 'completed')
		assert_eq(snap.completed, 2)
		assert_eq(snap.total, 2)

		assert_eq(snap.components.reader.status, 'ok')
		assert_eq(snap.components.reader.result.role, 'reader')

		assert_eq(snap.components.writer.status, 'ok')
		assert_eq(snap.components.writer.result.role, 'writer')
	end)
end

-------------------------------------------------------------------------------
-- Component failure is interpreted by default policy
-------------------------------------------------------------------------------

function tests.test_component_failure_fails_link_by_default_policy()
	fibers.run(function (root_scope)
		local st, rep, primary = run_link_in_child(root_scope, {
			link_id = 'link-b',

			components = {
				{
					name = 'reader',
					run = function ()
						error('reader exploded', 0)
					end,
				},

				{
					name = 'writer',
					run = function ()
						fibers.perform(sleep.sleep_op(1))
						return {
							role = 'writer',
						}
					end,
				},
			},
		})

		assert_eq(st, 'failed')
		assert_match(primary, 'component reader failed')
		assert_match(primary, 'reader exploded')

		assert_not_nil(rep)
	end)
end

-------------------------------------------------------------------------------
-- Component failure can be treated as data by explicit policy
-------------------------------------------------------------------------------

function tests.test_component_failure_is_data_when_policy_allows_it()
	fibers.run(function (root_scope)
		local seen_failed = false

		local st, rep, result = run_link_in_child(root_scope, {
			link_id = 'link-c',

			policy = function (_, ev)
				if ev.kind == 'component_done' and ev.component == 'reader' and ev.status == 'failed' then
					seen_failed = true
				end

				return {
					action = 'continue',
				}
			end,

			components = {
				{
					name = 'reader',
					run = function ()
						error('reader failed as data', 0)
					end,
				},

				{
					name = 'writer',
					run = function ()
						return {
							role = 'writer',
						}
					end,
				},
			},
		})

		assert_eq(st, 'ok')
		assert_eq(#rep.extra_errors, 0)
		assert_true(seen_failed)

		local snap = result.snapshot

		assert_eq(snap.state, 'completed')
		assert_eq(snap.completed, 2)

		assert_eq(snap.components.reader.status, 'failed')
		assert_match(snap.components.reader.primary, 'reader failed as data')

		assert_eq(snap.components.writer.status, 'ok')
	end)
end

-------------------------------------------------------------------------------
-- Unexpected component cancellation fails the link by default
-------------------------------------------------------------------------------

function tests.test_component_cancellation_fails_link_by_default_policy()
	fibers.run(function (root_scope)
		local st, _, primary = run_link_in_child(root_scope, {
			link_id = 'link-d',

			components = {
				{
					name = 'session',
					run = function (component_scope)
						component_scope:cancel('session stopped')
						fibers.perform(sleep.sleep_op(1))
						return {
							unreachable = true,
						}
					end,
				},
			},
		})

		assert_eq(st, 'failed')
		assert_match(primary, 'component session cancelled unexpectedly')
		assert_match(primary, 'session stopped')
	end)
end

-------------------------------------------------------------------------------
-- Link component run must return one result table
-------------------------------------------------------------------------------

function tests.test_component_must_return_result_table()
	fibers.run(function (root_scope)
		local st, _, primary = run_link_in_child(root_scope, {
			link_id = 'link-e',

			components = {
				{
					name = 'bad_component',
					run = function ()
						return 'not a table'
					end,
				},
			},
		})

		assert_eq(st, 'failed')
		assert_match(primary, 'component bad_component failed')
		assert_match(primary, 'worker must return one result table')
	end)
end

-------------------------------------------------------------------------------
-- Link start validates duplicate component names before work begins
-------------------------------------------------------------------------------

function tests.test_duplicate_component_names_are_rejected()
	fibers.run(function (root_scope)
		local st, _, primary = run_link_in_child(root_scope, {
			link_id = 'link-f',

			components = {
				{
					name = 'reader',
					run = function ()
						return {}
					end,
				},

				{
					name = 'reader',
					run = function ()
						return {}
					end,
				},
			},
		})

		assert_eq(st, 'failed')
		assert_match(primary, 'duplicate component name')
	end)
end

-------------------------------------------------------------------------------
-- Link result does not expose a live model owned by the completed scope
-------------------------------------------------------------------------------

function tests.test_link_result_exposes_snapshot_not_live_model()
	fibers.run(function (root_scope)
		local st, _, result = run_link_in_child(root_scope, {
			link_id = 'link-g',

			components = {
				{
					name = 'reader',
					run = function ()
						return {
							role = 'reader',
						}
					end,
				},
			},
		})

		assert_eq(st, 'ok')
		assert_not_nil(result.snapshot)
		assert_nil(result.model)
	end)
end


-------------------------------------------------------------------------------
-- Complete policy may not finish while components are still live
-------------------------------------------------------------------------------

function tests.test_complete_policy_action_is_rejected()
	fibers.run(function (root_scope)
		local st, _, primary = run_link_in_child(root_scope, {
			link_id = 'link-complete-early',

			policy = function (_, ev)
				if ev.kind == 'component_done' and ev.component == 'fast' then
					return {
						action = 'complete',
						reason = 'not_all_done',
					}
				end

				return {
					action = 'continue',
				}
			end,

			components = {
				{
					name = 'fast',
					run = function ()
						return {
							role = 'fast',
						}
					end,
				},

				{
					name = 'slow',
					run = function ()
						fibers.perform(sleep.sleep_op(10))
						return {
							role = 'slow',
						}
					end,
				},
			},
		})

		assert_eq(st, 'failed')
		assert_match(primary, 'unknown policy action: complete')
	end)
end


-------------------------------------------------------------------------------
-- Cancel policy state is not regressed by later component completions
-------------------------------------------------------------------------------

function tests.test_cancel_policy_state_does_not_regress_after_later_completion()
	fibers.run(function (root_scope)
		local st, _, result = run_link_in_child(root_scope, {
			link_id = 'link-cancel-regression',

			policy = function (_, ev)
				if ev.kind == 'component_done' and ev.component == 'fast' then
					return {
						action = 'cancel',
						reason = 'stop after fast',
					}
				end

				return { action = 'continue' }
			end,

			components = {
				{
					name = 'fast',
					run = function ()
						return { role = 'fast' }
					end,
				},

				{
					name = 'slow',
					run = function ()
						fibers.perform(sleep.sleep_op(10))
						return { role = 'slow' }
					end,
				},
			},
		})

		assert_eq(st, 'ok')
		assert_eq(result.snapshot.state, 'cancelling')
		assert_eq(result.snapshot.reason, 'stop after fast')
		assert_eq(result.snapshot.completed, 2)
		assert_eq(result.snapshot.components.fast.status, 'ok')
		assert_eq(result.snapshot.components.slow.status, 'cancelled')
	end)
end

-------------------------------------------------------------------------------
-- Component result mutation after reporting does not mutate public snapshots
-------------------------------------------------------------------------------

function tests.test_completion_result_mutation_after_reporting_does_not_mutate_snapshot()
	fibers.run(function (root_scope)
		local returned = { role = 'reader', value = 1 }

		local st, _, result = run_link_in_child(root_scope, {
			link_id = 'link-result-copy',

			components = {
				{
					name = 'reader',
					run = function ()
						return returned
					end,
				},
			},
		})

		assert_eq(st, 'ok')
		assert_eq(result.snapshot.components.reader.result.value, 1)

		returned.value = 99
		returned.role = 'mutated'

		assert_eq(result.snapshot.components.reader.result.value, 1)
		assert_eq(result.snapshot.components.reader.result.role, 'reader')
	end)
end


-------------------------------------------------------------------------------
-- Component workers receive narrowed link capabilities, not the link coordinator
-------------------------------------------------------------------------------

function tests.test_component_worker_receives_narrowed_link_capability()
	fibers.run(function (root_scope)
		local saw_caps = false

		local st, _, result = run_link_in_child(root_scope, {
			link_id = 'link-cap-test',

			components = {
				{
					name = 'reader',
					run = function (_, caps)
						saw_caps = true
						assert_eq(caps.link_id, 'link-cap-test')
						assert_eq(caps.component, 'reader')
						assert_eq(caps._model, nil)
						assert_eq(caps._components, nil)
						assert_eq(caps._done_tx, nil)
						assert_eq(type(caps.snapshot), 'table')
						return { role = 'reader' }
					end,
				},
			},
		})

		assert_eq(st, 'ok')
		assert_true(saw_caps)
		assert_eq(result.snapshot.components.reader.status, 'ok')
	end)
end


-------------------------------------------------------------------------------
-- Foreign component completions are ignored even when link_generation matches
-------------------------------------------------------------------------------

function tests.test_component_completion_with_wrong_link_id_is_ignored()
	local scoped_work = require 'devicecode.support.scoped_work'
	local old_start = scoped_work.start

	local ok_test, err_test = pcall(function ()
		scoped_work.start = function (spec)
			if spec
				and spec.identity
				and spec.identity.kind == 'component_done'
				and spec.identity.component == 'reader'
			then
				local orig_report = spec.report
				local wrapped = {}
				for k, v in pairs(spec) do wrapped[k] = v end

				wrapped.report = function (ev)
					local foreign = {}
					for k, v in pairs(ev) do foreign[k] = v end
					foreign.link_id = 'wrong-link-id'
					foreign.status = 'failed'
					foreign.primary = 'foreign completion should be ignored'

					local ok, err = orig_report(foreign)
					if ok ~= true then return ok, err end

					return orig_report(ev)
				end

				return old_start(wrapped)
			end

			return old_start(spec)
		end

		fibers.run(function (root_scope)
			local st, _, result = run_link_in_child(root_scope, {
				link_id = 'real-link-id',

				components = {
					{
						name = 'reader',
						run = function ()
							return { role = 'reader' }
						end,
					},
				},
			})

			assert_eq(st, 'ok')
			assert_eq(result.snapshot.link_id, 'real-link-id')
			assert_eq(result.snapshot.components.reader.status, 'ok')
			assert_eq(result.snapshot.components.reader.primary, nil)
		end)
	end)

	scoped_work.start = old_start

	if not ok_test then
		error(err_test, 0)
	end
end

return tests
