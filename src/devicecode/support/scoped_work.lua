-- devicecode/support/scoped_work.lua
--
-- Shared infrastructure for scoped Fabric/service work.
--
-- Responsibilities:
--   * create a child scope under the lifetime owner
--   * run the worker inside that child scope
--   * signal body-ended from wrapper code, not user code
--   * ordinary early reaping waits for body-ended before join_op()
--   * store completion exactly once
--   * let reporters observe stored completion without joining
--   * require explicit delegation for non-lifetime reaping
--
-- This module is infrastructure. It may use op.perform_raw for authorised
-- reaping so that outcome storage does not depend on the current scope staying
-- healthy.

local safe   = require 'coxpcall'

local fibers    = require 'fibers'
local op        = require 'fibers.op'
local cond      = require 'fibers.cond'
local tablex    = require 'shared.table'

local M = {}

local copy_table = tablex.shallow_copy

local function copy_value(v)
	if type(v) == 'table' then
		return copy_table(v)
	end
	return v
end

local function copy_completion(ev)
	if ev == nil then
		return nil
	end

	local out = copy_table(ev)
	out.result = copy_value(ev.result)
	out.report = copy_value(ev.report)
	out.primary = copy_value(ev.primary)
	return out
end

local function scope_not_ready(scope, name)
	if scope == nil then
		return name .. ' is required'
	end

	if type(scope.status) == 'function' then
		local st, reason = scope:status()
		if st ~= 'running' then
			return ('%s is not running: %s%s'):format(
				name,
				tostring(st),
				reason ~= nil and (': ' .. tostring(reason)) or ''
			)
		end
	end

	if type(scope.admission) == 'function' then
		local admission, reason = scope:admission()
		if admission ~= 'open' then
			return ('%s admission is not open: %s%s'):format(
				name,
				tostring(admission),
				reason ~= nil and (': ' .. tostring(reason)) or ''
			)
		end
	end

	return nil
end

local function make_completion(identity, status, report, result, primary)
	local ev = copy_table(identity)

	ev.status = status
	ev.report = copy_value(report)

	if status == 'ok' then
		ev.result = copy_value(result)
	else
		ev.primary = primary
	end

	return ev
end

local function validate_result(result)
	if type(result) ~= 'table' then
		error('scoped_work: worker must return one result table', 0)
	end
	return result
end

--- Start scoped work.
---
--- Required:
---   lifetime_scope : parent scope that owns the child lifetime
---   identity       : table copied into the eventual completion event
---   identity.kind  : string
---   run(scope)     : worker body; must return one result table on success
---
--- Optional:
---   reaper_scope        : where the authorised reaper fibre lives
---   report_scope        : where the reporter fibre lives
---   reaper_delegation   : required when reaper_scope ~= lifetime_scope
---   setup(scope)        : non-yielding setup hook before worker admission;
---                         returns setup table or nil,err
---                         setup table may include cancel_owned_now(reason),
---                         an immediate, non-yielding cancellation hook for
---                         setup-owned resources such as request owners
---   report(ev)          : immediate reporter callback; should not yield
---   copy_result(result) : optional body-end snapshot hook for successful result
---   cancel_op           : optional Op, or function(child, setup_result) -> Op;
---                         if it wins before body-ended and returns neither nil
---                         nor false, child scope is cancelled with that reason
---
---@param spec table
---@return table|nil handle
---@return string|nil err
---@return table|nil setup_result
local function start_impl(spec, opts)
	opts = opts or {}
	local cleanup_on_start_failure = not not opts.cleanup_on_start_failure
	if type(spec) ~= 'table' then
		return nil, 'scoped_work.start: spec must be a table'
	end

	local lifetime_scope = spec.lifetime_scope
	local reaper_scope   = spec.reaper_scope or lifetime_scope
	local report_scope   = spec.report_scope or reaper_scope

	local err

	err = scope_not_ready(lifetime_scope, 'lifetime_scope')
	if err then return nil, err end

	err = scope_not_ready(reaper_scope, 'reaper_scope')
	if err then return nil, err end

	if spec.report ~= nil then
		if type(spec.report) ~= 'function' then
			return nil, 'report must be a function when provided'
		end

		err = scope_not_ready(report_scope, 'report_scope')
		if err then return nil, err end
	end

	if reaper_scope ~= lifetime_scope and spec.reaper_delegation == nil then
		return nil, 'non-lifetime reaping requires explicit reaper_delegation'
	end

	if type(spec.identity) ~= 'table' then
		return nil, 'identity table required'
	end

	if type(spec.identity.kind) ~= 'string' then
		return nil, 'identity.kind string required'
	end

	if type(spec.run) ~= 'function' then
		return nil, 'run function required'
	end

	if spec.setup ~= nil and type(spec.setup) ~= 'function' then
		return nil, 'setup must be a function when provided'
	end

	if spec.copy_result ~= nil and type(spec.copy_result) ~= 'function' then
		return nil, 'copy_result must be a function when provided'
	end

	if spec.cancel_op ~= nil and type(spec.cancel_op) ~= 'table' and type(spec.cancel_op) ~= 'function' then
		return nil, 'cancel_op must be an Op or function when provided'
	end

	local identity = copy_table(spec.identity)
	local copy_result = spec.copy_result or copy_value

	local child, child_err = lifetime_scope:child()
	if not child then
		return nil, child_err or 'failed to create child scope'
	end

	local setup_result = nil

	local body_done    = cond.new()
	local outcome_done = cond.new()

	local result
	local failure_primary
	local outcome
	local reaped   = false
	local reported = false

	local function store_once(status, report, primary)
		if reaped then
			return false
		end

		reaped = true
		outcome = make_completion(identity, status, report, result, primary)
		outcome_done:signal()
		return true
	end

	local function outcome_snapshot()
		return copy_completion(outcome)
	end

	local function cancel_child_now(reason)
		reason = reason or 'cancelled'

		if setup_result and type(setup_result.cancel_owned_now) == 'function' then
			local ok, err = setup_result.cancel_owned_now(reason)
			if ok == false or ok == nil then
				return nil, err or 'scoped_work_cancel_owned_failed'
			end
		end

		child:cancel(reason)
		return true, nil
	end

	local function outcome_op()
		return op.guard(function ()
			if outcome ~= nil then
				return op.always(copy_completion(outcome))
			end

			return outcome_done:wait_op():wrap(function ()
				return copy_completion(outcome)
			end)
		end)
	end

	local function cancel_start_failure(reason)
		-- No worker body has been admitted. Suppress reporter output for this
		-- failed start, signal the body-ended barrier so an already-spawned
		-- reaper can make progress, and cancel the empty child.
		--
		-- If setup already transferred caller-visible resources into this helper,
		-- give them their immediate cancellation path now.  Parent join/finalisers
		-- remain the structural cleanup fallback and must be idempotent.
		--
		-- The normal public start() path deliberately does not join here: it is
		-- coordinator-safe and must not hide synchronous cleanup waits. Parent
		-- join remains the structural reaper of last resort. Setup-only callers
		-- may request bounded eager cleanup via start_setup_checked().
		reported = true
		if setup_result and type(setup_result.cancel_owned_now) == 'function' then
			setup_result.cancel_owned_now(reason or 'scoped_work_start_failed')
		end
		body_done:signal()
		child:cancel(reason or 'scoped_work_start_failed')

		if cleanup_on_start_failure then
			op.perform_raw(child:join_op())
		end
	end

	if spec.setup then
		local ok_setup, a, b = safe.pcall(function ()
			return spec.setup(child)
		end)

		if not ok_setup then
			cancel_start_failure(a or 'setup_failed')
			return nil, tostring(a or 'setup_failed')
		end

		if a == nil then
			local setup_err = b or 'setup_failed'
			cancel_start_failure(setup_err)
			return nil, tostring(setup_err)
		end

		if type(a) ~= 'table' then
			local setup_err = 'setup must return a table'
			cancel_start_failure(setup_err)
			return nil, setup_err
		end

		setup_result = a
	end

	local ok_reaper, reaper_spawn_err = reaper_scope:spawn(function ()
		-- Ordinary observation reaping must not close admission while the
		-- worker body may still legitimately spawn child work. The helper, not
		-- user code, signals this barrier. Start-failure paths signal it too so
		-- the reaper cannot be left parked on an empty child scope.
		op.perform_raw(body_done:wait_op())

		local status, report, primary = op.perform_raw(child:join_op())
		if status == 'failed' and failure_primary ~= nil then
			primary = copy_value(failure_primary)
		end
		store_once(status, report, primary)
	end)

	if ok_reaper ~= true then
		cancel_start_failure(reaper_spawn_err or 'reaper_spawn_failed')
		return nil, reaper_spawn_err or 'reaper_spawn_failed'
	end

	if spec.cancel_op ~= nil then
		local cancel_op = spec.cancel_op
		if type(cancel_op) == 'function' then
			local ok_cancel_op, cop_or_err = safe.pcall(function ()
				return cancel_op(child, setup_result)
			end)
			if not ok_cancel_op then
				cancel_start_failure(cop_or_err or 'cancel_op_setup_failed')
				return nil, tostring(cop_or_err or 'cancel_op_setup_failed')
			end
			cancel_op = cop_or_err
		end

		if cancel_op ~= nil then
			local ok_cancel, cancel_spawn_err = reaper_scope:spawn(function ()
				local which, reason = fibers.perform(op.named_choice({
					cancel = cancel_op,
					body_done = body_done:wait_op(),
				}))

				if which == 'cancel' and reason ~= nil and reason ~= false then
					local ok, cerr = cancel_child_now(reason)
					if ok ~= true then error(cerr or 'scoped_work_cancel_failed', 0) end
				end
			end)

			if ok_cancel ~= true then
				cancel_start_failure(cancel_spawn_err or 'cancel_watcher_spawn_failed')
				return nil, cancel_spawn_err or 'cancel_watcher_spawn_failed'
			end
		end
	end

	if spec.report then
		local ok_reporter, reporter_spawn_err = report_scope:spawn(function ()
			-- Reporter is ordinary observing-scope code. If its scope is
			-- cancelled before the outcome is available, it does not report.
			local ev = fibers.perform(outcome_op())

			if reported then
				return
			end
			reported = true

			local ok, report_err = spec.report(copy_completion(ev))
			if ok ~= true then
				error(report_err or 'scoped_work_report_failed', 0)
			end
		end)

		if ok_reporter ~= true then
			cancel_start_failure(reporter_spawn_err or 'reporter_spawn_failed')
			return nil, reporter_spawn_err or 'reporter_spawn_failed'
		end
	end

	local ok_worker, worker_spawn_err = child:spawn(function ()
		local ok, ret = safe.pcall(function ()
			-- Cancellation may have happened after admission but before this worker
			-- fibre first ran.  Observe the child scope before entering user code so
			-- pre-body cancellation cannot leak into HAL/Fabric work.
			child:perform(op.always(true))

			local raw = validate_result(spec.run(child, setup_result))
			return validate_result(copy_result(raw))
		end)

		if ok then
			-- Snapshot the worker result before join/finalisers run. Finalisers
			-- must not be able to mutate the eventual successful completion.
			result = ret
		elseif spec.preserve_error_primary == true then
			failure_primary = copy_value(ret)
		end

		-- This is wrapper-owned, not user-owned.
		body_done:signal()

		if not ok then
			error(ret, 0)
		end
	end)

	if ok_worker ~= true then
		cancel_start_failure(worker_spawn_err or 'worker_spawn_failed')
		return nil, worker_spawn_err or 'worker_spawn_failed'
	end

	local handle = {
		_identity = identity,
	}

	function handle:cancel(reason)
		return cancel_child_now(reason or 'cancelled')
	end

	function handle:outcome_op()
		return outcome_op()
	end

	function handle:outcome()
		return outcome_snapshot()
	end

	function handle:identity()
		return copy_table(identity)
	end

	return handle, nil, setup_result
end

--- Start scoped work in coordinator-safe mode. This function never calls
--- join_op() or perform_raw() synchronously on start-failure paths.
--- Failed starts may leave a cancelled attached child for the parent/reaper to
--- account for later.
function M.start(spec)
	return start_impl(spec, { cleanup_on_start_failure = false })
end

--- Start scoped work in setup-only mode. This preserves the stronger
--- no-attached-child-on-start-failure property by joining the just-created child
--- non-interruptibly if infrastructure admission fails. Do not call this from
--- strict coordinator branches.
function M.start_setup_checked(spec)
	return start_impl(spec, { cleanup_on_start_failure = true })
end

M.make_completion = make_completion
M.copy_completion = copy_completion

return M
