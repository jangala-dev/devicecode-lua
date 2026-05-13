local fibers = require 'fibers'
local op = require 'fibers.op'
local cond = require 'fibers.cond'
local mailbox = require 'fibers.mailbox'
local ingest = require 'services.update.ingest'
local lifetime = require 'services.update.artifacts.lifetime'
local preflight = require 'services.update.artifacts.preflight'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end

local function new_sink()
	local sink = { terminated = 0, appended = {}, committed = false }
	function sink:append_op(chunk)
		self.appended[#self.appended + 1] = chunk
		return op.always(true, nil)
	end
	function sink:commit_op()
		self.committed = true
		return op.always({ ref = 'artifact-1' }, nil)
	end
	function sink:terminate(reason)
		self.terminated = self.terminated + 1
		self.reason = reason
		return true, nil
	end
	return sink
end

function tests.test_ingest_scope_terminates_uncommitted_sink_from_finaliser()
	local sink = new_sink()
	fibers.run(function ()
		local st, rep, snap = fibers.run_scope(function (scope)
			local inst = assert(ingest.new_instance(scope, {
				ingest_id = 'i1',
				component = 'cm5',
				sink = sink,
			}))
			return inst:snapshot()
		end)
		assert_eq(st, 'ok')
		assert_eq(snap.ingest_id, 'i1')
	end)
	assert_eq(sink.terminated, 1)
end

function tests.test_ingest_commit_transfers_sink_cleanup_ownership()
	local sink = new_sink()
	fibers.run(function ()
		local st, rep, result = fibers.run_scope(function (scope)
			local inst = assert(ingest.new_instance(scope, {
				ingest_id = 'i1',
				component = 'cm5',
				sink = sink,
			}))
			local appended = assert(fibers.perform(assert(inst:append_op('abc'))))
			assert_eq(appended.bytes, 3)
			assert(inst:begin_commit())
			return assert(inst:commit_worker(scope))
		end)
		assert_eq(st, 'ok')
		assert_eq(result.artifact.ref, 'artifact-1')
	end)
	assert_true(sink.committed)
	assert_eq(sink.terminated, 0)
end

function tests.test_artifact_lifetime_terminate_uses_immediate_terminate()
	local sink = new_sink()
	fibers.run(function (scope)
		local owned = assert(lifetime.own(scope, sink))
		local ok = assert(owned:terminate('manual'))
		assert_eq(ok, true)
	end)
	assert_eq(sink.terminated, 1)
	assert_eq(sink.reason, 'manual')
end


local function new_req(payload)
	return {
		_update_method = payload and payload.method,
		payload = payload,
		reply_value = nil,
		fail_reason = nil,
		reply = function(self, v) self.reply_value = v; return true end,
		fail = function(self, r) self.fail_reason = r; return true end,
	}
end

function tests.test_ingest_terminal_request_is_selected_before_append()
	fibers.run(function (scope)
		local state = ingest.new_state(scope, { queue_len = 4 })
		local append_req = new_req({ method='ingest_append', ingest_id='i1', chunk='abc' })
		local commit_req = new_req({ method='ingest_commit', ingest_id='i1' })
		assert(state:submit(append_req))
		assert(state:submit(commit_req))
		local ev = state:try_terminal_now()
		assert_eq(ev.kind, 'ingest_request')
		assert_eq(ev.request, commit_req)
		local ev2 = state:try_request_now()
		assert_eq(ev2.request, append_req)
	end)
end

function tests.test_artifact_preflight_cleans_up_before_durable_handoff()
	local artifact = new_sink()
	fibers.run(function ()
		local st, rep, primary = fibers.run_scope(function (scope)
			return preflight.run(scope, {
				artifact = artifact,
				check = function () return nil, 'bad_artifact' end,
			})
		end)
		assert_eq(st, 'failed')
	end)
	assert_eq(artifact.terminated, 1)
end

function tests.test_artifact_preflight_does_not_cleanup_after_handoff()
	local artifact = new_sink()
	fibers.run(function ()
		local st, rep, result = fibers.run_scope(function (scope)
			return preflight.run(scope, {
				artifact = artifact,
				transfer = true,
				check = function () return { ok = true } end,
			})
		end)
		assert_eq(st, 'ok')
		assert_true(result.transferred)
	end)
	assert_eq(artifact.terminated, 0)
end

function tests.test_artifact_lifetime_rejects_close_only_resources()
	fibers.run(function (scope)
		local closed = 0
		local close_only = { close = function () closed = closed + 1; return true end }
		local owned, err = lifetime.own(scope, close_only)
		assert_eq(owned, nil)
		assert_eq(err, 'resource has no terminate(reason) method')
		assert_eq(closed, 0)
	end)
end

function tests.test_artifact_lifetime_rejects_async_close_without_immediate_cleanup()
	fibers.run(function (scope)
		local async_only = { ['close' .. '_op'] = function () return op.always(true, nil) end }
		local owned, err = lifetime.own(scope, async_only)
		assert_eq(owned, nil)
		assert_eq(err, 'resource exposes close_op but no terminate(reason) method')
	end)
end


function tests.test_ingest_instance_has_own_child_scope()
	local sink = new_sink()
	fibers.run(function ()
		local st, _, snap = fibers.run_scope(function (scope)
			local inst = assert(ingest.new_instance(scope, {
				ingest_id = 'i-scoped',
				component = 'cm5',
				sink = sink,
			}))
			if inst._scope == nil or inst._scope == scope then
				fail('ingest instance should own a child scope')
			end
			return inst:snapshot()
		end)
		assert_eq(st, 'ok')
		assert_eq(snap.ingest_id, 'i-scoped')
	end)
	assert_eq(sink.terminated, 1)
end

function tests.test_ingest_instance_scope_finalises_pending_requests()
	local sink = new_sink()
	local req = new_req({ method = 'ingest_append', ingest_id = 'i1', chunk = 'abc' })
	fibers.run(function ()
		local st = fibers.run_scope(function (scope)
			local inst = assert(ingest.new_instance(scope, {
				ingest_id = 'i1',
				component = 'cm5',
				sink = sink,
			}))
			inst.pending[#inst.pending + 1] = { req = req, category = 'append' }
		end)
		assert_eq(st, 'ok')
	end)
	assert_eq(req.fail_reason, 'ingest_instance_closed')
end

function tests.test_ingest_operations_are_serialised_per_instance_and_terminal_closes_append_admission()
	fibers.run(function (scope)
		local append_gate = cond.new()
		local sink = { appended = {}, commits = 0, terminated = 0 }
		function sink:append_op(chunk)
			return append_gate:wait_op():wrap(function ()
				self.appended[#self.appended + 1] = chunk
				return true, nil
			end)
		end
		function sink:commit_op()
			self.commits = self.commits + 1
			return op.always({ ref = 'artifact-serial' }, nil)
		end
		function sink:terminate(reason)
			self.terminated = self.terminated + 1
			self.reason = reason
			return true, nil
		end

		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local state = ingest.new_state(scope, { queue_len = 8 })
		local inst = assert(ingest.new_instance(scope, {
			ingest_id = 'i1',
			component = 'cm5',
			sink = sink,
		}))
		state._instances.i1 = inst
		local ctx = { scope = scope, request_root = scope, service_id = 'update', generation = 1, done_tx = done_tx }

		local append_req = new_req({ method = 'ingest_append', ingest_id = 'i1', chunk = 'abc' })
		local commit_req = new_req({ method = 'ingest_commit', ingest_id = 'i1' })
		local late_append = new_req({ method = 'ingest_append', ingest_id = 'i1', chunk = 'late' })

		state:handle_event(ctx, { kind = 'ingest_request', request = append_req })
		state:handle_event(ctx, { kind = 'ingest_request', request = commit_req })
		state:handle_event(ctx, { kind = 'ingest_request', request = late_append })

		assert_eq(sink.commits, 0, 'commit must not run while append is active')
		assert_eq(late_append.fail_reason, 'ingest_closing')

		append_gate:signal()
		local append_done = fibers.perform(done_rx:recv_op())
		assert_eq(append_done.status, 'ok', 'append should complete before terminal work starts')
		assert_eq(append_done.result.tag, 'ingest_appended')
		state:handle_done(ctx, append_done)

		-- handle_done admits the next queued instance operation, but does not
		-- synchronously run worker code inside the coordinator branch. The commit
		-- worker runs when the scheduler next gets control.
		assert(inst.active_request_id ~= nil, 'commit should be admitted after append completion')
		assert_eq(sink.commits, 0, 'coordinator branch must not synchronously run commit work')

		local commit_done = fibers.perform(done_rx:recv_op())
		assert_eq(sink.commits, 1, 'commit should run after scheduler progress')
		state:handle_done(ctx, commit_done)

		assert_eq(#sink.appended, 1)
		assert_eq(sink.appended[1], 'abc')
		assert_eq(append_req.reply_value.ok, true)
		assert_eq(commit_req.reply_value.ok, true)
		assert_eq(inst.state, 'committed')
		assert_eq(inst.closed, true)
	end)
end


function tests.test_ingest_commit_construction_does_not_mutate_instance_state()
	local sink = { terminated = 0 }
	function sink:commit_op()
		return op.always({ ref = 'artifact-constructed' }, nil)
	end
	function sink:terminate(reason)
		self.terminated = self.terminated + 1
		self.reason = reason
		return true, nil
	end
	fibers.run(function ()
		fibers.run_scope(function (scope)
			local inst = assert(ingest.new_instance(scope, {
				ingest_id = 'i-construct',
				component = 'cm5',
				sink = sink,
			}))
			assert_eq(inst.commit_op, nil, 'ingest instances must not expose state-mutating Op construction')
			assert_eq(inst.state, 'open')
			assert_eq(inst.closed, false)
			local ok_begin = assert(inst:begin_commit())
			assert_eq(ok_begin, true)
			assert_eq(inst.state, 'committing')
			local result = assert(inst:commit_worker(scope))
			assert_eq(result.artifact.ref, 'artifact-constructed')
		end)
	end)
end

return tests
