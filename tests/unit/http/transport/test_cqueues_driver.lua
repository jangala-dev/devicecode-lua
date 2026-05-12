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

local function yield_until(pred, msg)
	for _ = 1, 50 do
		if pred() then return true end
		yield_once()
	end
	error(msg or 'condition was not reached', 2)
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

function M.test_pollable_ready_op_does_not_retain_infinite_timeout_timers()
	local drv = assert(driver_mod.new { create_controller = false })
	local pollable = {
		pollfd = function () return nil end,
		events = function () return '' end,
		timeout = function () return math.huge end,
	}

	fibers.run(function (scope)
		local count = 0
		local before = runtime.current_scheduler.wheel.heap.size

		assert(scope:spawn(function ()
			while count < 20 do
				local reason, err = fibers.perform(drv:pollable_ready_op(pollable))
				eq(reason, 'poke')
				eq(err, nil)
				count = count + 1
			end
		end))

		yield_until(function ()
			drv:poke()
			return count >= 20
		end, 'pollable should wake from repeated pokes')

		local after = runtime.current_scheduler.wheel.heap.size
		eq(after, before, 'infinite cqueues timeouts must not leave scheduler timers behind')
		drv:terminate('done')
	end)
end

function M.test_pollable_ready_op_does_not_arm_timeout_when_fd_wait_is_present()
	local drv = assert(driver_mod.new { create_controller = false })
	local pollable = {
		pollfd = function () return 0 end,
		events = function () return 'r' end,
		timeout = function () return 60 end,
	}

	fibers.run(function (scope)
		local count = 0
		local before = runtime.current_scheduler.wheel.heap.size

		assert(scope:spawn(function ()
			while count < 20 do
				local reason, err = fibers.perform(drv:pollable_ready_op(pollable))
				ok(reason == 'poke' or reason == 'fd')
				eq(err, nil)
				count = count + 1
			end
		end))

		yield_until(function ()
			drv:poke()
			return count >= 20
		end, 'pollable should wake from repeated fd waits or pokes')

		local after = runtime.current_scheduler.wheel.heap.size
		eq(after, before, 'fd-backed cqueues waits must not retain scheduler timers')
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

return M
