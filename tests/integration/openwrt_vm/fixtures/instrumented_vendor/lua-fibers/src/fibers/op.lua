-- fibers/op.lua

--- Concurrent ML style operations for structured concurrency.
--- Provides composable operations (ops) that may complete immediately
--- or block, with support for choice, guards, negative acknowledgements
--- and abort/cleanup behaviour.
---@module 'fibers.op'

local runtime = require 'fibers.runtime'
local safe    = require 'coxpcall'
local oneshot = require 'fibers.oneshot'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local function id_wrap(...) return ... end

----------------------------------------------------------------------
-- Suspensions and completion tasks
----------------------------------------------------------------------

--- A suspension of a fiber waiting on an op.
---@class Suspension : Task
---@field state "waiting"|"synchronized"
---@field sched Scheduler
---@field fiber Fiber
---@field wrap WrapFn|nil
---@field val table|nil
local Suspension = {}
Suspension.__index = Suspension

---@class CompleteTask : Task
---@field suspension Suspension
---@field wrap WrapFn
---@field val table
local CompleteTask = {}
CompleteTask.__index = CompleteTask

function Suspension:waiting()
	return self.state == 'waiting'
end

function Suspension:add_cleanup(f)
	if type(f) ~= 'function' then
		error('cleanup must be a function', 2)
	end

	if self.cleaned then
		safe.pcall(f)
		return
	end

	local cs = self.cleanups
	if not cs then
		cs = {}
		self.cleanups = cs
	end

	cs[#cs + 1] = f
end

function Suspension:_run_cleanups()
	if self.cleaned then return end
	self.cleaned = true

	local cs = self.cleanups
	self.cleanups = nil
	if not cs then return end

	for i = #cs, 1, -1 do
		safe.pcall(cs[i])
		cs[i] = nil
	end
end

function Suspension:wakeup(task)
	self.sched:schedule(task)
end

function Suspension:at_time(t, task)
	return self.sched:schedule_at_time(t, task)
end

function Suspension:after(dt, task)
	return self.sched:schedule_after_sleep(dt, task)
end

function Suspension:complete(wrap, ...)
	assert(self:waiting())
	self.state = 'synchronized'
	self.wrap  = wrap
	self.val   = pack(...)
	self:_run_cleanups()
	self.sched:schedule(self)
end

function Suspension:complete_and_run(wrap, ...)
	assert(self:waiting())
	self.state = 'synchronized'
	self:_run_cleanups()
	return self.fiber:resume(wrap, ...)
end

function Suspension:complete_task(wrap, ...)
	return setmetatable({
		suspension = self,
		wrap       = wrap,
		val        = pack(...),
	}, CompleteTask)
end

function Suspension:run()
	assert(not self:waiting())
	return self.fiber:resume(self.wrap, unpack(self.val, 1, self.val.n))
end

local function new_suspension(sched, fib)
	return setmetatable({
		state    = 'waiting',
		sched    = sched,
		fiber    = fib,
		cleanups = nil,
		cleaned  = false,
	}, Suspension)
end

function CompleteTask:run()
	if self.suspension:waiting() then
		self.suspension:complete_and_run(
			self.wrap,
			unpack(self.val, 1, self.val.n)
		)
	end
end

function CompleteTask:cancel(reason)
	if self.suspension:waiting() then
		local msg = reason or 'cancelled'

		local function cancelled_wrap()
			return false, msg
		end

		self.suspension:complete(cancelled_wrap)
	end
end

----------------------------------------------------------------------
-- Op type
----------------------------------------------------------------------

---@alias WrapFn fun(...: any): ...
---@alias TryFn fun(): boolean, ...
---@alias BlockFn fun(suspension: Suspension, wrap_fn: WrapFn)

---@class NackCond
---@field wait_op fun(): Op
---@field signal fun()

---@class CompiledLeaf
---@field try_fn TryFn
---@field block_fn BlockFn
---@field wrap WrapFn
---@field nacks NackCond[]

---@class Op
---@field kind "prim"|"choice"|"guard"|"with_nack"|"wrap"|"abort"
---@field ops Op[]|nil
---@field builder fun(...: any): Op
---@field wrap_fn WrapFn|nil
---@field inner Op|nil
---@field abort_fn fun()|nil
---@field try_fn TryFn|nil
---@field block_fn BlockFn|nil
local Op = {}
Op.__index = Op

local perform

local function is_op(v)
	return type(v) == 'table' and getmetatable(v) == Op
end

--- Construct a primitive op.
---@param wrap_fn? WrapFn
---@param try_fn TryFn
---@param block_fn BlockFn
---@return Op
local function new_primitive(wrap_fn, try_fn, block_fn)
	if type(try_fn) ~= 'function' then
		error('new_primitive: try_fn must be a function', 2)
	end

	if type(block_fn) ~= 'function' then
		error('new_primitive: block_fn must be a function', 2)
	end

	if wrap_fn ~= nil and type(wrap_fn) ~= 'function' then
		error('new_primitive: wrap_fn must be a function or nil', 2)
	end

	return setmetatable({
		kind     = 'prim',
		wrap_fn  = wrap_fn or id_wrap,
		try_fn   = try_fn,
		block_fn = block_fn,
	}, Op)
end

--- Delayed op builder; executed once per synchronisation.
---@param g fun(): Op
---@return Op
local function guard(g)
	if type(g) ~= 'function' then
		error('guard expects a function', 2)
	end

	return setmetatable({
		kind    = 'guard',
		builder = g,
	}, Op)
end

--- CML-style with_nack.
---@param g fun(nack_op: Op): Op
---@return Op
local function with_nack(g)
	if type(g) ~= 'function' then
		error('with_nack expects a function', 2)
	end

	return setmetatable({
		kind    = 'with_nack',
		builder = g,
	}, Op)
end

--- Op that is immediately ready with the given results.
---@param ... any
---@return Op
local function always(...)
	local results = pack(...)

	return new_primitive(
		nil,
		function ()
			return true, unpack(results, 1, results.n)
		end,
		function ()
			error('always: block_fn should never run')
		end
	)
end

--- Op that never becomes ready.
---@return Op
local function never()
	return new_primitive(
		nil,
		function ()
			return false
		end,
		function ()
			-- Intentionally never completes the suspension.
		end
	)
end

local function append_choice_arg(out, v, level)
	level = level or 2

	if is_op(v) then
		if v.kind == 'choice' then
			for i = 1, #(v.ops or {}) do
				out[#out + 1] = v.ops[i]
			end
		else
			out[#out + 1] = v
		end

		return
	end

	if type(v) == 'table' then
		local n = #v

		for k in pairs(v) do
			if type(k) ~= 'number'
				or k < 1
				or k % 1 ~= 0
				or k > n
			then
				error('choice expects Op values or dense arrays of Op values', level)
			end
		end

		for i = 1, n do
			append_choice_arg(out, v[i], level + 1)
		end

		return
	end

	error('choice expects Op values or dense arrays of Op values', level)
end

--- Choice op over zero or more sub-ops.
---
--- Empty choice is valid and never becomes ready.
--- Nested choices are flattened.
---
--- Accepted forms:
---   choice(op_a, op_b)
---   choice({ op_a, op_b })
---   choice(op_a, { op_b, op_c })
---   choice()
---   choice({})
---@param ... Op|Op[]
---@return Op
local function choice(...)
	local ops = {}

	for i = 1, select('#', ...) do
		append_choice_arg(ops, select(i, ...), 2)
	end

	if #ops == 0 then return never() end
	if #ops == 1 then return ops[1] end

	return setmetatable({
		kind = 'choice',
		ops  = ops,
	}, Op)
end

function Op:wrap(f)
	if type(f) ~= 'function' then
		error('wrap expects a function', 2)
	end

	return setmetatable({
		kind    = 'wrap',
		inner   = self,
		wrap_fn = f,
	}, Op)
end

function Op:on_abort(f)
	if type(f) ~= 'function' then
		error('on_abort expects a function', 2)
	end

	return setmetatable({
		kind     = 'abort',
		inner    = self,
		abort_fn = f,
	}, Op)
end

----------------------------------------------------------------------
-- Nack conditions
----------------------------------------------------------------------

local function new_cond(opts)
	local abort_fn = opts and opts.abort_fn or nil

	local os = oneshot.new(function ()
		if abort_fn then
			safe.pcall(abort_fn)
		end
	end)

	local function wait_op()
		assert(not abort_fn, 'abort-only cond has no wait_op')

		return new_primitive(
			nil,

			function ()
				return os:is_triggered()
			end,

			function (suspension, wrap_fn)
				local cancel = os:add_waiter(function ()
					if suspension:waiting() then
						suspension:complete(wrap_fn)
					end
				end)

				suspension:add_cleanup(cancel)
			end
		)
	end

	return {
		wait_op = wait_op,

		signal = function ()
			os:signal()
		end,
	}
end

----------------------------------------------------------------------
-- Compile op tree
----------------------------------------------------------------------

---@param ev Op
---@param outer_wrap? WrapFn
---@param out? CompiledLeaf[]
---@param nacks? NackCond[]
---@return CompiledLeaf[]
local function compile_op(ev, outer_wrap, out, nacks)
	out        = out or {}
	outer_wrap = outer_wrap or id_wrap
	nacks      = nacks or {}

	if ev.kind == 'choice' then
		for _, sub in ipairs(ev.ops or {}) do
			compile_op(sub, outer_wrap, out, nacks)
		end

	elseif ev.kind == 'guard' then
		local inner = ev.builder()
		compile_op(inner, outer_wrap, out, nacks)

	elseif ev.kind == 'with_nack' then
		local cond = new_cond()
		local inner = ev.builder(cond.wait_op())
		local child_nacks = { unpack(nacks) }

		child_nacks[#child_nacks + 1] = cond
		compile_op(inner, outer_wrap, out, child_nacks)

	elseif ev.kind == 'wrap' then
		local f = assert(ev.wrap_fn)

		local new_outer = function (...)
			return outer_wrap(f(...))
		end

		compile_op(ev.inner, new_outer, out, nacks)

	elseif ev.kind == 'abort' then
		local cond = new_cond({ abort_fn = ev.abort_fn })
		local child_nacks = { unpack(nacks) }

		child_nacks[#child_nacks + 1] = cond
		compile_op(ev.inner, outer_wrap, out, child_nacks)

	else
		local function wrapped(...)
			return outer_wrap(ev.wrap_fn(...))
		end

		out[#out + 1] = {
			try_fn   = ev.try_fn,
			block_fn = ev.block_fn,
			wrap     = wrapped,
			nacks    = nacks,
		}
	end

	return out
end

----------------------------------------------------------------------
-- Nacks and readiness
----------------------------------------------------------------------

local function trigger_nacks(leaves, winner_index)
	local winner_set

	if winner_index then
		winner_set = {}

		for _, cond in ipairs(leaves[winner_index].nacks or {}) do
			winner_set[cond] = true
		end
	end

	local signalled = {}

	for i = 1, #leaves do
		if not winner_index or i ~= winner_index then
			for j = #(leaves[i].nacks or {}), 1, -1 do
				local cond = leaves[i].nacks[j]

				if cond
					and not (winner_set and winner_set[cond])
					and not signalled[cond]
				then
					signalled[cond] = true
					cond.signal()
				end
			end
		end
	end
end

local function try_ready(leaves)
	local n = #leaves
	if n == 0 then return nil end

	local start = math.random(n)

	for k = 0, n - 1 do
		local idx = ((start + k - 1) % n) + 1
		local leaf = leaves[idx]
		local retval = pack(leaf.try_fn())

		if retval[1] then
			return idx, retval
		end
	end

	return nil
end

local function apply_wrap(wrap, retval)
	assert(retval ~= nil, 'apply_wrap: retval must not be nil')
	return wrap(unpack(retval, 2, retval.n))
end

----------------------------------------------------------------------
-- or_else
----------------------------------------------------------------------

--- Non-blocking choice: try this op, otherwise run fallback_thunk.
---@param fallback_thunk fun(): any
---@return Op
function Op:or_else(fallback_thunk)
	if type(fallback_thunk) ~= 'function' then
		error('or_else expects a function', 2)
	end

	if self.kind == 'prim' then
		local try_fn  = assert(self.try_fn)
		local wrap_fn = assert(self.wrap_fn)

		return new_primitive(
			nil,

			function ()
				local r = pack(try_fn())

				if r[1] then
					return true, wrap_fn(unpack(r, 2, r.n))
				end

				return true, fallback_thunk()
			end,

			function ()
				error('or_else(prim): block_fn should never run')
			end
		)
	end

	return guard(function ()
		local leaves = compile_op(self)
		local idx, retval = try_ready(leaves)

		if idx then
			trigger_nacks(leaves, idx)

			local results = pack(apply_wrap(leaves[idx].wrap, retval))
			return always(unpack(results, 1, results.n))
		end

		trigger_nacks(leaves, nil)

		local results = pack(fallback_thunk())
		return always(unpack(results, 1, results.n))
	end)
end

----------------------------------------------------------------------
-- Blocking path
----------------------------------------------------------------------

local function block_choice_op(sched, fib, leaves)
	local suspension = new_suspension(sched, fib)

	for _, leaf in ipairs(leaves) do
		leaf.block_fn(suspension, leaf.wrap)
	end
end

local function block_prim_op(sched, fib, prim)
	local suspension = new_suspension(sched, fib)
	prim.block_fn(suspension, prim.wrap_fn)
end

----------------------------------------------------------------------
-- Perform
----------------------------------------------------------------------

perform = function (ev)
	if not runtime.current_fiber() then
		error('perform_raw must be called from inside a fiber (use fibers.run as an entry point)', 2)
	end

	if ev.kind == 'guard' then
		return perform(ev.builder())
	end

	if ev.kind == 'prim' then
		local r = pack(ev.try_fn())

		if r[1] then
			return ev.wrap_fn(unpack(r, 2, r.n))
		end

		local suspended = pack(runtime.suspend(block_prim_op, ev))
		local wrap = suspended[1]

		return wrap(unpack(suspended, 2, suspended.n))
	end

	local leaves = compile_op(ev)

	local idx, retval = try_ready(leaves)
	if idx then
		trigger_nacks(leaves, idx)
		return apply_wrap(leaves[idx].wrap, retval)
	end

	local suspended = pack(runtime.suspend(block_choice_op, leaves))
	local wrap = suspended[1]

	local winner_index

	for i, leaf in ipairs(leaves) do
		if leaf.wrap == wrap then
			winner_index = i
			break
		end
	end

	trigger_nacks(leaves, winner_index)

	return wrap(unpack(suspended, 2, suspended.n))
end

----------------------------------------------------------------------
-- bracket / finally
----------------------------------------------------------------------

local function bracket(acquire, release, use)
	if type(acquire) ~= 'function' then
		error('bracket: acquire must be a function', 2)
	end

	if type(release) ~= 'function' then
		error('bracket: release must be a function', 2)
	end

	if type(use) ~= 'function' then
		error('bracket: use must be a function', 2)
	end

	return guard(function ()
		local res = acquire()
		local used = use(res)

		local wrapped = used:wrap(function (...)
			release(res, false)
			return ...
		end)

		return wrapped:on_abort(function ()
			release(res, true)
		end)
	end)
end

function Op:finally(cleanup)
	if type(cleanup) ~= 'function' then
		error('finally expects a function', 2)
	end

	return bracket(
		function () return nil end,
		function (_, aborted) cleanup(aborted) end,
		function () return self end
	)
end

----------------------------------------------------------------------
-- Higher-level choice helpers
----------------------------------------------------------------------

local function race(ops, on_win)
	if type(on_win) ~= 'function' then
		error('race expects on_win callback', 2)
	end

	if type(ops) ~= 'table' then
		error('race expects a dense array of Op values', 2)
	end

	local wrapped = {}

	for i, ev in ipairs(ops) do
		if not is_op(ev) then
			error('race expects a dense array of Op values', 2)
		end

		wrapped[i] = ev:wrap(function (...)
			return on_win(i, ...)
		end)
	end

	return choice(wrapped)
end

local function first_ready(ops)
	return race(ops, function (i, ...)
		return i, ...
	end)
end

local function named_choice(arms)
	if type(arms) ~= 'table' then
		error('named_choice expects a table of Op values', 2)
	end

	local ops, names = {}, {}

	for name, ev in pairs(arms) do
		if not is_op(ev) then
			error('named_choice expects a table of Op values', 2)
		end

		names[#names + 1] = name
		ops[#ops + 1] = ev
	end

	return race(ops, function (i, ...)
		return names[i], ...
	end)
end

local function boolean_choice(op_true, op_false)
	if not is_op(op_true) or not is_op(op_false) then
		error('boolean_choice expects two Op values', 2)
	end

	return race({ op_true, op_false }, function (i, ...)
		if i == 1 then
			return true, ...
		end

		return false, ...
	end)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	perform_raw    = perform,
	new_primitive  = new_primitive,
	choice         = choice,
	guard          = guard,
	with_nack      = with_nack,
	bracket        = bracket,
	always         = always,
	never          = never,
	Op             = Op,
	race           = race,
	first_ready    = first_ready,
	named_choice   = named_choice,
	boolean_choice = boolean_choice,
}
