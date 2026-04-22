-- services/update/await.lua
--
-- Small reconcile waiting helper.
--
-- Responsibilities:
--   * repeatedly evaluate backend-visible facts
--   * wait for either:
--       - observed state change
--       - timeout expiry
--   * expose both:
--       - until_changed_or_timeout_op(...) for composition
--       - until_changed_or_timeout(...) as the ordinary blocking wrapper
--
-- Design note:
--   the core loop remains imperative for clarity; the op form is the
--   compositional boundary around that loop.

local fibers = require 'fibers'
local scope = require 'fibers.scope'
local sleep = require 'fibers.sleep'

local perform = fibers.perform
local named_choice = fibers.named_choice
local now = fibers.now
local run_scope_op = fibers.run_scope_op

local M = {}

local function until_changed_or_timeout_blocking(opts)
	assert(type(opts) == 'table', 'await.until_changed_or_timeout: opts must be a table')
	assert(type(opts.version) == 'function', 'await.until_changed_or_timeout: version() required')
	assert(type(opts.changed_op) == 'function', 'await.until_changed_or_timeout: changed_op() required')
	assert(type(opts.evaluate) == 'function', 'await.until_changed_or_timeout: evaluate() required')

	local timeout_s = assert(tonumber(opts.timeout_s), 'await.until_changed_or_timeout: timeout_s required')
	local deadline = now() + timeout_s

	while true do
		local seen = opts.version()
		local result = opts.evaluate()

		if result ~= nil then
			if result.done then
				if result.success then
					return 'success', result
				end
				return 'failure', result
			end
			if opts.on_progress then
				opts.on_progress(result)
			end
		end

		local remaining = deadline - now()
		if remaining <= 0 then
			return 'timeout', nil
		end

		local which = perform(named_choice({
			changed = opts.changed_op(seen),
			timeout = sleep.sleep_op(remaining):wrap(function()
				return true
			end),
		}))

		if which == 'timeout' then
			return 'timeout', nil
		end
	end
end

function M.until_changed_or_timeout_op(opts)
	return run_scope_op(function()
		return until_changed_or_timeout_blocking(opts)
	end):wrap(function(st, _rep, a, b)
		if st == 'ok' then
			return a, b
		elseif st == 'cancelled' then
			return 'cancelled', a
		else
			return 'error', a
		end
	end)
end

function M.until_changed_or_timeout(opts)
	local outcome, result = perform(M.until_changed_or_timeout_op(opts))
	if outcome == 'cancelled' then
		error(scope.cancelled(result), 0)
	elseif outcome == 'error' then
		error(result or 'await_failed', 0)
	end
	return outcome, result
end

return M
