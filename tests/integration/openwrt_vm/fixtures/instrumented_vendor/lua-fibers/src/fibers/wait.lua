---
-- Wait module.
--
-- Internal helper utilities for building blocking primitives:
--
--   * Waitset: keyed sets of waiting tasks with unlink tokens.
--   * waitable(register, step, wrap_fn?): build an op from
--       a step function and a registration function.
--
-- This module is intended for backend / primitive implementations
-- (pollers, in-memory pipes, streams, timers). Normal library users
-- should not need to depend on it directly.
--
-- Design notes:
--   - This module is exception-neutral. It does not interpret Lua
--     errors as part of op semantics.
--   - step() and register(...) are assumed to be non-blocking and
--     non-yielding. If they raise, this is treated as a bug and the
--     surrounding scope/fiber machinery will surface the failure.
---@module 'fibers.wait'

local op = require 'fibers.op'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local function id_wrap(...)
	return ...
end

----------------------------------------------------------------------
-- Waitset: keyed lists of tasks with unlink tokens
----------------------------------------------------------------------

--- Keyed set of scheduler tasks grouped by an arbitrary key.
---@class Waitset
---@field buckets table<any, Task[]>  # key -> list of scheduler tasks
local Waitset = {}
Waitset.__index = Waitset

--- Token returned from Waitset:add.
--- unlink() removes the task from the waitset; it is idempotent.
---@class WaitToken
---@field _waitset Waitset
---@field key any
---@field task Task
---@field unlink fun(self: WaitToken): boolean  # true if bucket emptied

--- Create a new Waitset instance.
---@return Waitset
local function new_waitset()
	return setmetatable({ buckets = {} }, Waitset)
end

--- Remove element at index i by swapping with the tail.
---@param t Task[]
---@param i integer
local function remove_at(t, i)
	local n = #t
	t[i] = t[n]
	t[n] = nil
end

--- Add a task under a given key.
--
-- @param key   Arbitrary key (fd, object, tag, etc.).
-- @param task  Scheduler task object (must have :run()).
--
-- @return token  Table with token:unlink() -> bucket_empty:boolean.
---@param key any
---@param task Task
---@return WaitToken
function Waitset:add(key, task)
	local buckets = self.buckets
	local list = buckets[key]
	if not list then
		list = {}
		buckets[key] = list
	end

	list[#list + 1] = task
	local idx       = #list
	local unlinked  = false

	---@class WaitToken
	local token = {
		_waitset = self,
		key      = key,
		task     = task,
	}

	--- Unlink this task from the waitset.
	--- Best-effort: falls back to a reverse scan if the stored index
	--- has been invalidated by earlier removals.
	---@param tok WaitToken
	---@return boolean bucket_empty
	function token.unlink(tok)
		if unlinked then
			return false
		end
		unlinked = true

		local bs = tok._waitset.buckets
		local l  = bs[tok.key]
		if not l or #l == 0 then
			return false
		end

		-- Best-effort removal; index may be stale.
		if idx <= #l and l[idx] == tok.task then
			remove_at(l, idx)
		else
			for i = #l, 1, -1 do
				if l[i] == tok.task then
					remove_at(l, i)
					break
				end
			end
		end

		if #l == 0 then
			bs[tok.key] = nil
			return true
		end
		return false
	end

	return token
end

--- Take and remove all waiters for a key.
---
--- Returns the list (which the caller may iterate and discard), or nil.
---@param key any
---@return Task[]|nil
function Waitset:take_all(key)
	local list = self.buckets[key]
	if not list then
		return nil
	end
	self.buckets[key] = nil
	return list
end

--- Take and remove a single waiter (LIFO) for a key.
---
--- Returns the task or nil.
---@param key any
---@return Task|nil
function Waitset:take_one(key)
	local list = self.buckets[key]
	if not list or #list == 0 then
		return nil
	end
	local idx  = #list
	local task = list[idx]
	list[idx]  = nil
	if #list == 0 then
		self.buckets[key] = nil
	end
	return task
end

--- Return whether there are no waiters for this key.
---@param key any
---@return boolean
function Waitset:is_empty(key)
	local list = self.buckets[key]
	return not list or #list == 0
end

--- Return the number of waiters for this key.
---@param key any
---@return integer
function Waitset:size(key)
	local list = self.buckets[key]
	return list and #list or 0
end

--- Remove all waiters for a single key without notifying them.
---@param key any
function Waitset:clear_key(key)
	self.buckets[key] = nil
end

--- Remove all waiters for all keys without notifying them.
function Waitset:clear_all()
	self.buckets = {}
end

--- Notify and schedule all waiters for a key.
---@param key any
---@param scheduler Scheduler
function Waitset:notify_all(key, scheduler)
	local list = self:take_all(key)
	if not list then return end
	for i = 1, #list do
		scheduler:schedule(list[i])
		list[i] = nil
	end
end

--- Notify and schedule a single waiter (LIFO) for a key.
---@param key any
---@param scheduler Scheduler
function Waitset:notify_one(key, scheduler)
	local task = self:take_one(key)
	if not task then return end
	scheduler:schedule(task)
end

----------------------------------------------------------------------
-- waitable: (register, step, wrap_fn?) -> Op
-- waitable2: (register, probe_step, run_step, wrap_fn?) -> Op
----------------------------------------------------------------------

-- Normalise "want" without restricting it to rd/wr/any.
--   * nil/false -> nil
--   * 'any' is treated specially by register_with_want
--   * everything else is passed through to register(...)
local function normalise_want(want)
	return (want == nil or want == false) and nil or want
end

--- Build a waitable Op from a register function and two step functions.
--
--   probe_step() -> done:boolean, ...
--     * Must be non-blocking and must not yield.
--     * Should be side-effect neutral when returning done==false.
--     * May return (false, want) where want is any token understood by register().
--
--   run_step() -> done:boolean, ...
--     * Must be non-blocking and must not yield.
--     * May perform stateful progress (e.g. fill buffers, advance state machines).
--
--   register(task, waker, want) -> token
--     * Must arrange for task:run() when progress may be possible.
--     * want is passed through (except 'any', see below).
--     * token:unlink() (if present) is called on abort to cancel registration.
--
--   waker capability:
--     * waker:wakeup(task)
--     * waker:at_time(t, task)
--     * waker:after(dt, task)
--
-- Special want:
--   * want == 'any' registers both ('rd' and 'wr') and unlinks both on abort.
--
---@param register fun(task: Task, waker: table, want: any): WaitToken
---@param probe_step fun(): boolean, ...
---@param run_step fun(): boolean, ...
---@param wrap_fn? WrapFn
---@return Op
local function waitable2(register, probe_step, run_step, wrap_fn)
	assert(type(register) == 'function', 'waitable2: register must be a function')
	assert(type(probe_step) == 'function', 'waitable2: probe_step must be a function')
	assert(type(run_step) == 'function', 'waitable2: run_step must be a function')

	wrap_fn = wrap_fn or id_wrap

	return op.guard(function ()
		local token, last_want, cleanup_added, waker

		local function unlink()
			local t = token
			token = nil
			if t and t.unlink then t:unlink() end
		end

		local function capture_want(step_fn)
			local r = pack(step_fn())
			last_want = r[1] and nil or normalise_want(r[2])
			return r
		end

		local function register_any(task, waker_)
			local t1 = register(task, waker_, 'rd')
			local t2 = register(task, waker_, 'wr')
			return {
				unlink = function ()
					if t1 and t1.unlink then t1:unlink() end
					if t2 and t2.unlink then t2:unlink() end
					return false
				end,
			}
		end

		local function arm(task, suspension, leaf_wrap, want)
			if not cleanup_added then
				cleanup_added = true
				suspension:add_cleanup(unlink)
			end

			unlink()

			if want == 'any' then
				token = register_any(task, waker) -- see note below
			else
				token = register(task, waker, want)
			end
		end

		local function try()
			local r = capture_want(probe_step)
			return unpack(r, 1, r.n)
		end

		local function block(suspension, leaf_wrap)
			waker = {
				wakeup = function (_, task_) suspension:wakeup(task_) end,
				at_time = function (_, t, task_) suspension:at_time(t, task_) end,
				after = function (_, dt, task_) suspension:after(dt, task_) end,
			}

			local task
			task = {
				run = function ()
					if not suspension:waiting() then return end

					local r = capture_want(run_step)
					if r[1] then
						unlink()
						return suspension:complete(leaf_wrap, unpack(r, 2, r.n))
					end

					arm(task, suspension, leaf_wrap, last_want)
				end,
			}

			-- Use want captured by the most recent try().
			arm(task, suspension, leaf_wrap, last_want)
		end

		return op.new_primitive(wrap_fn, try, block):on_abort(unlink)
	end)
end


--- Backwards-compatible wrapper: a single step is used for both probe and run.
---@param register fun(task: Task, waker: table, want: any): WaitToken
---@param step fun(): boolean, ...
---@param wrap_fn? WrapFn
---@return Op
local function waitable(register, step, wrap_fn)
	return waitable2(register, step, step, wrap_fn)
end

return {
	new_waitset = new_waitset,
	waitable    = waitable,
	waitable2   = waitable2,
}
