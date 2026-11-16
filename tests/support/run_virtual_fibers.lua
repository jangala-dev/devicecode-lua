local fibers = require 'fibers'
local safe = require 'coxpcall'
local virtual_time = require 'tests.support.virtual_time'
local time_harness = require 'tests.support.time_harness'
local pulse = require 'fibers.pulse'

local M = {}

-- Runs a test with a cancellable child scope and a scheduler-backed virtual clock.
-- This deliberately has no fibers sleep timeout: advancing the virtual clock would
-- advance that timeout too. Callers must use bounded tick helpers for convergence.
function M.run(fn, opts)
	opts = opts or {}
	local ok, err = safe.pcall(function()
		fibers.run(function(root_scope)
			local clock = virtual_time.install({
				monotonic = opts.monotonic,
				realtime = opts.realtime,
				follow_realtime = opts.follow_realtime,
			})
			local test_scope, child_err = root_scope:child()
			if not test_scope then
				clock:restore()
				error(child_err, 0)
			end

			local body_ok, body_err = safe.pcall(function()
				fn(test_scope, clock)
			end)

			test_scope:cancel('test complete')
			local join_ok, status, primary = safe.pcall(function()
				local st, _, fault = fibers.perform(test_scope:join_op())
				return st, fault
			end)
			clock:restore()

			if not body_ok then error(body_err, 0) end
			if not join_ok then error(status, 0) end
			if status == 'failed' then error(primary or 'virtual test child scope failed', 0) end
		end)
	end)

	if not ok then error(err, 0) end
end

-- For in-process tests whose body already waits on fiber timers. Run the body
-- concurrently with a bounded clock driver, preserving its sleeps and production
-- deadlines. Real sockets, subprocesses and external clocks need run_fibers instead.
-- Use run() and explicit advances when asserting a particular deadline boundary.
function M.run_auto(fn, opts)
	opts = opts or {}
	M.run(function(scope, clock)
		local done = pulse.new()
		local version = done:version()
		local body_scope = assert(scope:child())
		local body_ok, body_err
		assert(body_scope:spawn(function(s)
			body_ok, body_err = safe.pcall(fn, s, clock)
			done:signal()
		end))

		-- Let startup work settle before the first clock advance. Each subsequent
		-- millisecond also allows bounded scheduler turns for bus/service work.
		local completed = time_harness.wait_op_ticks(function()
			return done:changed_op(version)
		end, { max_ticks = 100 })
		if not completed then
			completed = time_harness.wait_op_within(clock, opts.timeout or 10, function()
				return done:changed_op(version)
			end, { step = 0.001, max_ticks = 20 })
		end
		-- Keep driving time while cancelled workers and finalisers finish too.
		body_scope:cancel(completed and 'test complete' or 'test timeout')
		local joined = pulse.new()
		local joined_version = joined:version()
		local status, primary
		assert(scope:spawn(function()
			local st, _, fault = fibers.perform(body_scope:join_op())
			status, primary = st, fault
			joined:signal()
		end))
		-- Scope finalisers are noninterruptible, as in run_fibers. The timeout
		-- bounds the body, not cleanup: keep finite cleanup timers moving even
		-- after that budget expires. Tests of stuck raw cleanup need a process
		-- watchdog, since no in-process runner can cancel a raw never-Op.
		repeat
			local cleaned = time_harness.wait_op_within(clock, 1, function()
				return joined:changed_op(joined_version)
			end, { step = 0.001, max_ticks = 20 })
		until cleaned
		assert(completed, ('test timed out after %.3fs of virtual time'):format(opts.timeout or 10))
		if not body_ok then error(body_err, 0) end
		if status == 'failed' then error(primary or 'virtual test child scope failed', 0) end
	end, {
		-- Some service caches reserve zero for an unobserved timestamp.
		monotonic = opts.monotonic or 100,
		realtime = opts.realtime or 1700000000,
		follow_realtime = opts.follow_realtime,
	})
end

return M
