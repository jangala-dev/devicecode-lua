-- tests/unit/support/test_scoped_work.lua
--
-- Standalone semantic tests for devicecode.support.scoped_work.
--
-- Run with package.path pointing at src/, for example:
--
local fibers      = require 'fibers'
local sleep       = require 'fibers.sleep'
local mailbox     = require 'fibers.mailbox'
local cond        = require 'fibers.cond'
local scoped_work = require 'devicecode.support.scoped_work'
local queue       = require 'devicecode.support.queue'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then
		fail(msg or ('expected true, got ' .. tostring(v)))
	end
end

local function assert_false(v, msg)
	if v ~= false then
		fail(msg or ('expected false, got ' .. tostring(v)))
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

local function child_scope(parent)
	local child, err = parent:child()
	assert_not_nil(child, err)
	return child
end

local function capture_next_child(parent)
	local old_child = parent.child
	local captured

	function parent:child(...)
		local child, err
		if old_child then
			child, err = old_child(self, ...)
		else
			child, err = getmetatable(self).__index.child(self, ...)
		end

		captured = child
		return child, err
	end

	return function ()
		parent.child = old_child
		return captured
	end
end

local function start_required(spec)
	local handle, err = scoped_work.start(spec)
	assert_not_nil(handle, err)
	return handle
end

-------------------------------------------------------------------------------
-- 1. body-ended happens before ordinary reaping
-------------------------------------------------------------------------------

function tests.test_body_ended_happens_before_ordinary_reaping()
	fibers.run(function (scope)
		local late_spawn_ok = false
		local late_child_ran = false

		local handle = start_required {
			lifetime_scope = scope,

			identity = {
				kind = 'body_done_test',
				id   = 'work-1',
			},

			run = function (work_scope)
				-- Give an unsafe reaper a chance to run. If it joined immediately,
				-- it would close child admission before the spawn below.
				fibers.perform(sleep.sleep_op(0.001))

				local ok, err = work_scope:spawn(function ()
					late_child_ran = true
				end)

				late_spawn_ok = ok == true

				if not ok then
					error(err or 'late spawn rejected', 0)
				end

				return {
					ok = true,
				}
			end,
		}

		local ev = fibers.perform(handle:outcome_op())

		assert_eq(ev.kind, 'body_done_test')
		assert_eq(ev.status, 'ok')
		assert_true(late_spawn_ok, 'late child spawn should be admitted before reaping')
		assert_true(late_child_ran, 'late child should be joined before outcome is stored')
	end)
end

-------------------------------------------------------------------------------
-- 2. reporter does not call join_op
-------------------------------------------------------------------------------

function tests.test_reporter_does_not_call_join_op()
	fibers.run(function (scope)
		local report_scope = child_scope(scope)
		local report_tx, report_rx = mailbox.new(4, { full = 'reject_newest' })
		local captured_child = capture_next_child(scope)

		local handle = start_required {
			lifetime_scope = scope,
			reaper_scope   = scope,
			report_scope   = report_scope,

			identity = {
				kind = 'reporter_join_test',
				id   = 'work-2',
			},

			run = function ()
				fibers.perform(sleep.sleep_op(0.001))
				return {
					ok = true,
				}
			end,

			report = function (ev)
				return queue.try_admit_required(report_tx, ev, 'report_failed')
			end,
		}

		local child = captured_child()
		assert_not_nil(child, 'expected captured child scope')
		local old_join_op = child.join_op
		local join_count = 0

		function child:join_op(...)
			join_count = join_count + 1
			return old_join_op(self, ...)
		end

		local ev = fibers.perform(report_rx:recv_op())

		assert_not_nil(ev, 'expected reported completion')
		assert_eq(ev.kind, 'reporter_join_test')
		assert_eq(ev.status, 'ok')
		assert_eq(join_count, 1, 'only the authorised reaper should call join_op')
	end)
end

-------------------------------------------------------------------------------
-- 3. non-parent / non-lifetime reaping requires explicit delegation
-------------------------------------------------------------------------------

function tests.test_non_lifetime_reaping_requires_delegation()
	fibers.run(function (scope)
		local reaper_scope = child_scope(scope)

		local handle, err = scoped_work.start {
			lifetime_scope = scope,
			reaper_scope   = reaper_scope,

			identity = {
				kind = 'delegation_test',
				id   = 'work-3',
			},

			run = function ()
				return {
					ok = true,
				}
			end,
		}

		assert_nil(handle)
		assert_match(err, 'reaping requires explicit reaper_delegation')
	end)
end

-------------------------------------------------------------------------------
-- 4. stored completion survives reporter cancellation
-------------------------------------------------------------------------------

function tests.test_stored_completion_survives_reporter_cancellation()
	fibers.run(function (scope)
		local report_scope = child_scope(scope)
		local report_count = 0

		local handle = start_required {
			lifetime_scope = scope,
			reaper_scope   = scope,
			report_scope   = report_scope,

			identity = {
				kind = 'reporter_cancel_test',
				id   = 'work-4',
			},

			run = function ()
				fibers.perform(sleep.sleep_op(0.001))
				return {
					ok = true,
					value = 42,
				}
			end,

			report = function (_)
				report_count = report_count + 1
				return true
			end,
		}

		-- The reporter scope is cancelled before the outcome exists. This must
		-- not prevent the authorised reaper from storing the outcome.
		report_scope:cancel('observer stopped')

		local ev = fibers.perform(handle:outcome_op())

		assert_eq(ev.kind, 'reporter_cancel_test')
		assert_eq(ev.status, 'ok')
		assert_eq(ev.result.value, 42)
		assert_eq(report_count, 0, 'cancelled reporter should not report')
	end)
end

-------------------------------------------------------------------------------
-- 5. start failure leaves no live child
-------------------------------------------------------------------------------

function tests.test_start_failure_leaves_no_live_child()
	fibers.run(function (scope)
		local lifetime_scope = child_scope(scope)
		local report_scope   = child_scope(scope)

		report_scope:cancel('reporter unavailable')

		local handle, err = scoped_work.start {
			lifetime_scope = lifetime_scope,
			report_scope   = report_scope,

			identity = {
				kind = 'start_failure_test',
				id   = 'work-5',
			},

			run = function ()
				return {
					ok = true,
				}
			end,

			report = function ()
				return true
			end,
		}

		assert_nil(handle)
		assert_match(err, 'report_scope is not running')

		local st, rep = fibers.perform(lifetime_scope:join_op())

		assert_eq(st, 'ok')
		assert_eq(#rep.children, 0, 'failed start should not create an attached work child')
	end)
end


-------------------------------------------------------------------------------
-- 6. worker is not admitted until reporter infrastructure is ready
-------------------------------------------------------------------------------

function tests.test_worker_not_started_when_reporter_spawn_fails()
	fibers.run(function (scope)
		local lifetime_scope = child_scope(scope)
		local worker_started = false
		local reporter_spawn_attempted = false

		local fake_report_scope = {
			status = function ()
				return 'running', nil
			end,

			admission = function ()
				return 'open', nil
			end,

			spawn = function ()
				reporter_spawn_attempted = true
				return false, 'synthetic reporter spawn failure'
			end,
		}

		local handle, err = scoped_work.start {
			lifetime_scope = lifetime_scope,
			report_scope   = fake_report_scope,

			identity = {
				kind = 'admission_order_test',
				id   = 'work-6',
			},

			run = function ()
				worker_started = true
				return {
					ok = true,
				}
			end,

			report = function ()
				return true
			end,
		}

		assert_nil(handle)
		assert_match(err, 'synthetic reporter spawn failure')
		assert_true(reporter_spawn_attempted, 'reporter spawn should have been attempted')
		assert_false(worker_started, 'worker must not start until reporting infrastructure is admitted')

		local st, rep = fibers.perform(lifetime_scope:join_op())
		assert_eq(st, 'ok')
		assert_eq(#rep.children, 0, 'failed start should not leave an attached work child')
	end)
end


-------------------------------------------------------------------------------
-- 7. success path does not start join inline from scoped_work.start
-------------------------------------------------------------------------------

function tests.test_success_path_does_not_run_join_inline()
	fibers.run(function (scope)
		local release = cond.new()
		local captured_child = capture_next_child(scope)

		local handle = start_required {
			lifetime_scope = scope,

			identity = {
				kind = 'no_inline_join_test',
				id   = 'work-7',
			},

			run = function ()
				fibers.perform(release:wait_op())
				return { ok = true }
			end,
		}

		local child = captured_child()
		assert_not_nil(child, 'expected captured child scope')
		local old_join_op = child.join_op
		local join_count = 0

		function child:join_op(...)
			join_count = join_count + 1
			return old_join_op(self, ...)
		end

		fibers.perform(sleep.sleep_op(0.001))
		assert_eq(join_count, 0, 'successful start must not join the child inline')
		assert_nil(handle:outcome(), 'outcome should not be stored before body ends')

		release:signal()

		local ev = fibers.perform(handle:outcome_op())
		assert_eq(ev.status, 'ok')
		assert_eq(join_count, 1, 'authorised reaper should join after body-ended')
	end)
end

-------------------------------------------------------------------------------
-- 8. normal start failure is coordinator-safe and leaves structural cleanup to parent join
-------------------------------------------------------------------------------

function tests.test_normal_start_failure_does_not_join_inline_and_parent_reports_child()
	fibers.run(function (scope)
		local lifetime_scope = child_scope(scope)
		local reaper_spawn_attempted = false
		local worker_started = false

		local fake_reaper_scope = {
			status = function ()
				return 'running', nil
			end,

			admission = function ()
				return 'open', nil
			end,

			spawn = function ()
				reaper_spawn_attempted = true
				return false, 'synthetic reaper spawn failure'
			end,
		}

		local handle, err = scoped_work.start {
			lifetime_scope = lifetime_scope,
			reaper_scope   = fake_reaper_scope,
			reaper_delegation = 'unit-test delegated reaper',

			identity = {
				kind = 'reaper_start_failure_test',
				id   = 'work-8',
			},

			run = function ()
				worker_started = true
				return { ok = true }
			end,
		}

		assert_nil(handle)
		assert_match(err, 'synthetic reaper spawn failure')
		assert_true(reaper_spawn_attempted)
		assert_false(worker_started, 'worker must not be admitted when reaper infrastructure fails')

		local st, rep = fibers.perform(lifetime_scope:join_op())
		assert_eq(st, 'ok')
		assert_eq(#rep.children, 1, 'coordinator-safe failed start should leave parent join to account for child')
		assert_eq(rep.children[1].status, 'cancelled')
	end)
end


-------------------------------------------------------------------------------
-- 8b. setup-checked start failure performs eager cleanup and leaves no child
-------------------------------------------------------------------------------

function tests.test_setup_checked_start_failure_performs_eager_cleanup()
	fibers.run(function (scope)
		local lifetime_scope = child_scope(scope)
		local fake_reaper_scope = {
			status = function () return 'running', nil end,
			admission = function () return 'open', nil end,
			spawn = function () return false, 'synthetic reaper spawn failure' end,
		}

		local handle, err = scoped_work.start_setup_checked {
			lifetime_scope = lifetime_scope,
			reaper_scope = fake_reaper_scope,
			reaper_delegation = 'unit-test delegated reaper',

			identity = {
				kind = 'setup_checked_failure_test',
				id = 'work-8b',
			},

			run = function ()
				return { ok = true }
			end,
		}

		assert_nil(handle)
		assert_match(err, 'synthetic reaper spawn failure')

		local st, rep = fibers.perform(lifetime_scope:join_op())
		assert_eq(st, 'ok')
		assert_eq(#rep.children, 0, 'setup-checked failed start should eagerly reap the empty child')
	end)
end


-------------------------------------------------------------------------------
-- 9. production handle does not expose raw child-scope join authority
-------------------------------------------------------------------------------

function tests.test_production_handle_does_not_expose_join_authority()
	fibers.run(function (scope)
		local handle = start_required {
			lifetime_scope = scope,

			identity = {
				kind = 'handle_surface_test',
				id   = 'work-9',
			},

			run = function ()
				return { ok = true }
			end,
		}

		assert_eq(type(handle.cancel), 'function')
		assert_eq(type(handle.outcome_op), 'function')
		assert_eq(type(handle.outcome), 'function')
		assert_eq(type(handle.identity), 'function')
		assert_nil(handle.scope, 'production handle must not expose child scope')
		assert_nil(handle.join_op, 'production handle must not expose join authority')
		assert_nil(handle._scope, 'production handle must not carry raw child scope')

		local ev = fibers.perform(handle:outcome_op())
		assert_eq(ev.status, 'ok')
	end)
end


-------------------------------------------------------------------------------
-- 10. report queue overflow fails observing scope, not child work scope
-------------------------------------------------------------------------------

function tests.test_report_queue_overflow_fails_observer_not_child_work()
	fibers.run(function (scope)
		local report_scope = child_scope(scope)
		local report_tx, _ = mailbox.new(0, { full = 'reject_newest' })

		local handle = start_required {
			lifetime_scope = scope,
			reaper_scope   = scope,
			report_scope   = report_scope,

			identity = {
				kind = 'report_overflow_test',
				id   = 'work-10',
			},

			run = function ()
				return { ok = true }
			end,

			report = function (ev)
				return queue.try_admit_required(report_tx, ev, 'synthetic_report_overflow')
			end,
		}

		local ev = fibers.perform(handle:outcome_op())
		assert_eq(ev.status, 'ok', 'child work outcome should be stored as ok')

		local st, _, primary = fibers.perform(report_scope:join_op())
		assert_eq(st, 'failed')
		assert_match(primary, 'synthetic_report_overflow')
	end)
end


-------------------------------------------------------------------------------
-- 11. completion envelopes are copied at report and observe boundaries
-------------------------------------------------------------------------------

function tests.test_completion_envelopes_are_copied_on_report_and_observe()
	fibers.run(function (scope)
		local report_tx, report_rx = mailbox.new(4, { full = 'reject_newest' })

		local handle = start_required {
			lifetime_scope = scope,

			identity = {
				kind = 'completion_copy_test',
				id   = 'work-11',
			},

			run = function ()
				return {
					value = 1,
				}
			end,

			report = function (ev)
				ev.result.value = 99
				ev.kind = 'mutated_report'
				return queue.try_admit_required(report_tx, ev, 'copy_report_failed')
			end,
		}

		local reported = fibers.perform(report_rx:recv_op())
		assert_eq(reported.kind, 'mutated_report')
		assert_eq(reported.result.value, 99)

		local observed = fibers.perform(handle:outcome_op())
		assert_eq(observed.kind, 'completion_copy_test')
		assert_eq(observed.result.value, 1)

		observed.result.value = 123
		observed.kind = 'mutated_observer'

		local observed_again = handle:outcome()
		assert_eq(observed_again.kind, 'completion_copy_test')
		assert_eq(observed_again.result.value, 1)
	end)
end


-------------------------------------------------------------------------------
-- 12. successful result is snapshotted before child finalisers run
-------------------------------------------------------------------------------

function tests.test_worker_result_is_snapshotted_before_finalisers_mutate_it()
	fibers.run(function (scope)
		local returned = { value = 1 }

		local handle = start_required {
			lifetime_scope = scope,

			identity = {
				kind = 'result_snapshot_before_finaliser_test',
				id   = 'work-12',
			},

			run = function (work_scope)
				work_scope:finally(function ()
					returned.value = 99
					returned.extra = 'mutated by finaliser'
				end)

				return returned
			end,
		}

		local ev = fibers.perform(handle:outcome_op())
		assert_eq(ev.status, 'ok')
		assert_eq(ev.result.value, 1)
		assert_nil(ev.result.extra)
	end)
end


-------------------------------------------------------------------------------
-- 13. setup hook provides internal setup data without exposing it on handle
-------------------------------------------------------------------------------

function tests.test_setup_hook_runs_before_worker_and_returns_internal_data()
	fibers.run(function (scope)
		local setup_seen_by_worker = false
		local setup_child_status

		local handle, err, setup = scoped_work.start {
			lifetime_scope = scope,

			identity = {
				kind = 'setup_hook_test',
				id   = 'work-13',
			},

			setup = function (work_scope)
				local owned_child, child_err = work_scope:child()
				if not owned_child then
					return nil, child_err
				end

				owned_child:finally(function (_, status)
					setup_child_status = status
				end)

				return {
					owned_child = owned_child,
					marker = 'setup-complete',
				}
			end,

			run = function (_, setup_data)
				assert_eq(setup_data.marker, 'setup-complete')
				setup_seen_by_worker = true
				return { ok = true }
			end,
		}

		assert_not_nil(handle, err)
		assert_not_nil(setup)
		assert_not_nil(setup.owned_child)
		assert_nil(handle.setup, 'production handle must not expose setup data')
		assert_nil(handle.scope, 'production handle must not expose work scope')

		local ev = fibers.perform(handle:outcome_op())
		assert_eq(ev.status, 'ok')
		assert_true(setup_seen_by_worker)
		assert_eq(setup_child_status, 'ok')
	end)
end

-------------------------------------------------------------------------------
-- 14. setup failure cancels the just-created child but does not start worker
-------------------------------------------------------------------------------

function tests.test_setup_failure_prevents_worker_start_and_is_structurally_reported()
	fibers.run(function (scope)
		local lifetime_scope = child_scope(scope)
		local worker_started = false

		local handle, err = scoped_work.start {
			lifetime_scope = lifetime_scope,

			identity = {
				kind = 'setup_failure_test',
				id = 'work-14',
			},

			setup = function ()
				return nil, 'synthetic setup failure'
			end,

			run = function ()
				worker_started = true
				return { ok = true }
			end,
		}

		assert_nil(handle)
		assert_match(err, 'synthetic setup failure')
		assert_false(worker_started)

		local st, rep = fibers.perform(lifetime_scope:join_op())
		assert_eq(st, 'ok')
		assert_eq(#rep.children, 1)
		assert_eq(rep.children[1].status, 'cancelled')
		assert_match(tostring(rep.children[1].primary), 'synthetic setup failure')
	end)
end


-------------------------------------------------------------------------------
-- 15. setup-owned resources are finalised on post-setup start failure
-------------------------------------------------------------------------------

function tests.test_post_setup_start_failure_runs_cancel_owned_now()
	fibers.run(function (scope)
		local lifetime_scope = child_scope(scope)
		local finalised
		local fake_report_scope = {
			status = function () return 'running', nil end,
			admission = function () return 'open', nil end,
			spawn = function () return false, 'synthetic reporter spawn failure' end,
		}

		local handle, err = scoped_work.start {
			lifetime_scope = lifetime_scope,
			report_scope = fake_report_scope,

			identity = {
				kind = 'setup_owned_cancel_test',
				id = 'work-15',
			},

			setup = function ()
				return {
					cancel_owned_now = function (reason)
						finalised = reason
						return true
					end,
				}
			end,

			run = function ()
				return { ok = true }
			end,

			report = function ()
				return true
			end,
		}

		assert_nil(handle)
		assert_match(err, 'synthetic reporter spawn failure')
		assert_eq(finalised, 'synthetic reporter spawn failure')
	end)
end

return tests
