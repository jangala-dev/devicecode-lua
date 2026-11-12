local fibers = require 'fibers'
local safe = require 'coxpcall'
local virtual_time = require 'tests.support.virtual_time'

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

return M
