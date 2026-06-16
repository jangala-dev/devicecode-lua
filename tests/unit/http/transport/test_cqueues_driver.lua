local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local driver_mod = require 'services.http.transport.cqueues_driver'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
end

local function yield_once()
	runtime.yield()
end

local function yield_many(n)
	for _ = 1, n do yield_once() end
end

local function join_child_with_timeout(child, timeout_s)
	local which = fibers.perform(fibers.named_choice {
		joined = child:join_op(),
		timeout = sleep.sleep_op(timeout_s or 1),
	})
	return which == 'joined'
end

local function yield_until(pred, msg)
	for _ = 1, 50 do
		if pred() then return true end
		yield_once()
	end
	error(msg or 'condition was not reached', 2)
end

local function shell_quote(s)
	s = tostring(s or '')
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function shell_exit_status(a, b, c)
	if type(a) == 'number' then
		if a >= 256 then return math.floor(a / 256) end
		return a
	end
	if a == true then return 0 end
	if b == 'exit' and type(c) == 'number' then return c end
	if type(c) == 'number' then return c end
	return 1
end

local function run_filtered_child(filter, timeout_s)
	local cmd = ('timeout %s env TEST_FILTER=%s luajit run.lua'):format(
		tostring(timeout_s or 2), shell_quote(filter))
	return shell_exit_status(os.execute(cmd))
end

local function fake_controller()
	local q = {}
	return {
		wraps = 0,
		steps = 0,
		closed = false,
		wrap = function (self, fn)
			self.wraps = self.wraps + 1
			q[#q + 1] = fn
			return self
		end,
		step = function (self, timeout)
			eq(timeout, 0, 'driver must step with timeout 0')
			self.steps = self.steps + 1
			local fn = table.remove(q, 1)
			if fn then fn() end
			return true
		end,
		pollfd = function () return nil end,
		events = function () return '' end,
		timeout = function () return nil end,
		queued = function () return #q end,
	}
end

function M.test_event_wants_maps_cqueues_event_strings()
	local rd, wr = driver_mod.event_wants('r')
	ok(rd, 'r should want read')
	ok(not wr, 'r should not want write')

	rd, wr = driver_mod.event_wants('w')
	ok(not rd, 'w should not want read')
	ok(wr, 'w should want write')

	rd, wr = driver_mod.event_wants('p')
	ok(rd, 'priority event should map to read-side wake')
	ok(not wr, 'p should not want write')

	rd, wr = driver_mod.event_wants('rw')
	ok(rd and wr, 'rw should want both directions')
end

function M.test_pollable_ready_op_uses_poke_as_step_hint()
	local drv = assert(driver_mod.new { create_controller = false })
	local pollable = {
		pollfd = function () return nil end,
		events = function () return '' end,
		timeout = function () return nil end,
	}

	fibers.run(function (scope)
		local reason, err
		assert(scope:spawn(function ()
			reason, err = fibers.perform(drv:pollable_ready_op(pollable))
		end))
		yield_many(3)
		drv:poke()
		yield_many(3)
		eq(reason, 'poke')
		eq(err, nil)
		drv:terminate('done')
	end)
end

function M.test_pollable_ready_op_reports_due_timeout_immediately()
	local drv = assert(driver_mod.new { create_controller = false })
	local pollable = { timeout = function () return 0 end }

	fibers.run(function ()
		local reason, err = fibers.perform(drv:pollable_ready_op(pollable))
		eq(reason, 'timeout')
		eq(err, nil)
		drv:terminate('done')
	end)
end

function M.test_pollable_step_op_treats_spurious_timeout_step_as_nonfatal()
	local drv = assert(driver_mod.new { create_controller = false })
	local pollable = {
		timeout = function () return 0 end,
		step = function (_, timeout)
			eq(timeout, 0)
			return nil, 'timeout'
		end,
	}

	fibers.run(function ()
		local ok1, err = fibers.perform(drv:pollable_step_op(pollable))
		eq(ok1, true)
		eq(err, nil)
		drv:terminate('done')
	end)
end

function M.test_run_op_completes_inside_driver_pump()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })

	fibers.run(function (scope)
		assert(drv:start(scope))
		local a, b = fibers.perform(drv:run_op('unit.job', function ()
			return 'done', 42
		end))
		eq(a, 'done')
		eq(b, 42)
		ok(ctl.wraps >= 1, 'controller.wrap should be used')
		ok(ctl.steps >= 1, 'controller.step should be used')
		drv:terminate('test complete')
	end)
end

function M.test_run_op_reports_lua_errors_as_failed_results()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })

	fibers.run(function (scope)
		assert(drv:start(scope))
		local v, err = fibers.perform(drv:run_op('unit.error', function ()
			error('boom', 0)
		end))
		eq(v, nil)
		ok(tostring(err):find('boom', 1, true) ~= nil, 'error should be reported')
		drv:terminate('test complete')
	end)
end

function M.test_losing_run_op_aborts_without_running_job()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local aborted = false
	local ran = false

	fibers.run(function (scope)
		assert(drv:start(scope))

		local which = fibers.perform(fibers.named_choice {
			winner = fibers.always('now'),
			job = drv:run_op('unit.loser', function ()
				ran = true
				return 'late'
			end, {
				on_abort = function () aborted = true end,
			}),
		})

		eq(which, 'winner')
		ok(aborted, 'losing job should be abandoned')
		ctl:step(0)
		ok(not ran, 'abandoned job body must not run')
		drv:terminate('test complete')
	end)
end

function M.test_losing_active_run_op_calls_active_abort_without_closing_driver()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local active = false
	local release = false
	local active_abort

	fibers.run(function (scope)
		assert(drv:start(scope))

		local waiter = assert(scope:child())
		local result, err
		assert(waiter:spawn(function ()
			result, err = fibers.perform(drv:run_op('unit.active_loser', function ()
				active = true
				while not release do runtime.yield() end
				return 'late'
			end, {
				on_active_abort = function (reason)
					active_abort = reason
					release = true
				end,
			}))
		end))

		yield_until(function () return active end, 'job should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		eq(active_abort, 'aborted')
		ok(not drv:is_closed(), 'active abort with a narrow owner must not close the driver')
		release = true
		yield_many(3)
		eq(result, nil)
		eq(err, nil)
		drv:terminate('done')
	end)
end


function M.test_losing_active_run_op_can_detach_and_cleanup_after_cqueues_completion()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local active = false
	local release = false
	local detach_reason
	local cleanup_reason
	local cleanup_result

	fibers.run(function (scope)
		assert(drv:start(scope))

		local waiter = assert(scope:child())
		local result, err
		assert(waiter:spawn(function ()
			result, err = fibers.perform(drv:run_op('unit.active_detached', function ()
				active = true
				while not release do runtime.yield() end
				return 'late_result'
			end, {
				detach_on_abort = true,
				on_detach = function (reason) detach_reason = reason end,
				on_detached_complete = function (reason, ok, packed)
					cleanup_reason = reason
					if ok and packed then cleanup_result = packed[1] end
				end,
			}))
		end))

		yield_until(function () return active end, 'job should become active')
		waiter:cancel('stop_waiting')
		if not join_child_with_timeout(waiter, 0.25) then
			release = true
			drv:terminate('detached test bounded failure')
			join_child_with_timeout(waiter, 0.25)
			error('detached run_op caller did not return after abort; active cqueues jobs must detach caller cleanup', 2)
		end
		eq(result, nil)
		eq(err, nil)
		eq(detach_reason, 'aborted')
		ok(not drv:is_closed(), 'detached active abort must not close driver')
		release = true
		yield_until(function () return cleanup_reason == 'aborted' end, 'detached cleanup should run after cqueues job returns')
		eq(cleanup_result, 'late_result')
		ok(not drv:is_closed(), 'detached cleanup must not close driver')
		drv:terminate('done')
	end)
end

function M.test_losing_active_run_op_without_owner_terminates_driver()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local active = false

	fibers.run(function (scope)
		assert(drv:start(scope))

		local waiter = assert(scope:child())
		assert(waiter:spawn(function ()
			fibers.perform(drv:run_op('unit.active_loser_no_owner', function ()
				active = true
				while not drv:is_closed() do runtime.yield() end
				return 'late'
			end))
		end))

		yield_until(function () return active end, 'job should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		ok(drv:is_closed(), 'active abort with no narrower owner should close the driver')
		eq(drv:why(), 'aborted')
	end)
end

function M.test_active_aborted_job_late_completion_is_ignored()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local active = false
	local release = false
	local active_abort = 0

	fibers.run(function (scope)
		assert(drv:start(scope))

		local waiter = assert(scope:child())
		local result, err
		assert(waiter:spawn(function ()
			result, err = fibers.perform(drv:run_op('unit.active_late_completion', function ()
				active = true
				while not release do runtime.yield() end
				return 'late_result'
			end, {
				on_active_abort = function ()
					active_abort = active_abort + 1
				end,
			}))
		end))

		yield_until(function () return active end, 'job should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		eq(active_abort, 1)
		release = true
		yield_many(5)
		eq(result, nil)
		eq(err, nil)
		ok(not drv:is_closed(), 'owned active abort should not close driver')
		drv:terminate('done')
	end)
end

function M.test_terminate_wakes_pending_run_op_without_pump()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })

	fibers.run(function (scope)
		local result, err
		assert(scope:spawn(function ()
			result, err = fibers.perform(drv:run_op('unit.never', function ()
				return 'should not matter'
			end))
		end))

		yield_many(3)
		drv:terminate('stopping')
		yield_many(3)

		eq(result, nil)
		eq(err, 'stopping')
	end)
end

function M.test_multiple_concurrent_run_ops_are_completed_by_one_pump()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })

	fibers.run(function (scope)
		local a, b
		assert(drv:start(scope))
		assert(scope:spawn(function () a = fibers.perform(drv:run_op('a', function () return 'A' end)) end))
		assert(scope:spawn(function () b = fibers.perform(drv:run_op('b', function () return 'B' end)) end))

		for _ = 1, 5 do yield_once() end
		eq(a, 'A')
		eq(b, 'B')
		ok(ctl.steps >= 2, 'pump should step enough to complete queued jobs')
		drv:terminate('done')
	end)
end

function M.test_driver_scope_finaliser_terminates_driver_after_scope_cancel()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })

	fibers.run(function (scope)
		local child = assert(scope:child())
		assert(child:spawn(function (s)
			assert(drv:start(s))
			-- Keep the component scope alive until cancellation.
			fibers.perform(sleep.sleep_op(60))
		end))
		yield_once()
		child:cancel('stop')
		fibers.perform(child:join_op())
		ok(drv:is_closed(), 'driver should be closed by scope finaliser')
	end)
end


function M.test_driver_start_can_target_started_parent_scope_from_child_scope()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })

	fibers.run(function (parent)
		local child = assert(parent:child())
		local started, start_err

		assert(child:spawn(function ()
			started, start_err = drv:start(parent)
		end))

		yield_many(3)
		eq(started, true)
		eq(start_err, nil)
		drv:terminate('done')
	end)
end


-- Keep this ownership-boundary regression under the same focused regression filter as the
-- hostile real-HTTP test.  Run the raw payload in a subprocess: the old
-- hard-close-only implementation can wedge the Fibers scheduler so an
-- in-process watchdog cannot fire reliably.  The subprocess timeout turns that
-- into a bounded, clear test failure.
function M.test_metrics_style_exchange_timeout_regression_cqueues_driver_detaches_active_job_cleanup_to_cqueues_job()
	local code = run_filtered_child('test_losing_active_run_op_can_detach_and_cleanup_after_cqueues_completion',
		tonumber(os.getenv('HTTP_METRICS_TIMEOUT_UNIT_CHILD_TIMEOUT_S') or '') or 2)
	eq(code, 0, 'detached cqueues-driver ownership payload should pass in a bounded child process')
end

return M
