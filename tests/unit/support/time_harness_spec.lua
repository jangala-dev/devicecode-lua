local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local time = require 'fibers.utils.time'
local safe = require 'coxpcall'
local run_virtual_fibers = require 'tests.support.run_virtual_fibers'

local T = {}

local function snapshot()
	local scheduler = runtime.current_scheduler
	return { monotonic = time.monotonic, realtime = time.realtime, block = time._block,
		get_time = scheduler.get_time }
end

local function assert_restored(before)
	assert(time.monotonic == before.monotonic)
	assert(time.realtime == before.realtime)
	assert(time._block == before.block)
	assert(runtime.current_scheduler.get_time == before.get_time)
	assert(math.abs(runtime.current_scheduler.wheel.now - time.monotonic()) < 0.1)
end

function T.auto_clock_preserves_timer_order_and_settles_runnable_work()
	local before = snapshot()
	run_virtual_fibers.run_auto(function(scope, clock)
		assert(clock:monotonic() == 0)
		assert(clock:realtime() == 1700000000)
		local order = {}
		assert(scope:spawn(function()
			for _ = 1, 30 do runtime.yield() end
			assert(clock:monotonic() == 0, 'startup must settle before advancing time')
			order[#order + 1] = 'ready'
		end))
		assert(scope:spawn(function()
			sleep.sleep(1)
			order[#order + 1] = 'first'
		end))
		sleep.sleep(2)
		assert(table.concat(order, ',') == 'ready,first')
		assert(clock:monotonic() >= 2 and clock:monotonic() < 2.01)
		assert(math.abs(clock:realtime() - 1700000002) < 0.01)
	end, { monotonic = 0 })
	assert_restored(before)
end

function T.auto_clock_timeout_cancels_pending_work_and_restores_clock()
	local before = snapshot()
	local cleaned = false
	local ok, err = safe.pcall(function()
		run_virtual_fibers.run_auto(function(scope)
			scope:finally(function()
				op.perform_raw(sleep.sleep_op(0.03))
				cleaned = true
			end)
			fibers.perform(op.never())
		end, { timeout = 0.02 })
	end)
	assert(not ok and tostring(err):find('test timed out after 0.020s of virtual time', 1, true), tostring(err))
	assert(cleaned)
	assert_restored(before)
	-- A subsequent test can install a new clock after a timeout.
	run_virtual_fibers.run_auto(function() sleep.sleep(0.01) end)
end

function T.auto_clock_body_failure_is_reported_and_restores_clock()
	local before = snapshot()
	local cleaned = false
	local ok, err = safe.pcall(function()
		run_virtual_fibers.run_auto(function(scope)
			scope:finally(function() cleaned = true end)
			sleep.sleep(0.01)
			error('expected body failure')
		end)
	end)
	assert(not ok and tostring(err):find('expected body failure', 1, true), tostring(err))
	assert(cleaned)
	assert_restored(before)
end

function T.auto_clock_child_failure_is_reported_and_restores_clock()
	local before = snapshot()
	local ok, err = safe.pcall(function()
		run_virtual_fibers.run_auto(function(scope)
			assert(scope:spawn(function() error('expected child failure') end))
			fibers.perform(op.never())
		end)
	end)
	assert(not ok and tostring(err):find('expected child failure', 1, true), tostring(err))
	assert_restored(before)
end

function T.auto_clock_drives_timed_cleanup_before_restoring_clock()
	local before = snapshot()
	local cleaned = false
	run_virtual_fibers.run_auto(function(scope)
		scope:finally(function()
			op.perform_raw(sleep.sleep_op(0.03))
			cleaned = true
		end)
	end, { timeout = 0.02 })
	assert(cleaned)
	assert_restored(before)
end

return T
