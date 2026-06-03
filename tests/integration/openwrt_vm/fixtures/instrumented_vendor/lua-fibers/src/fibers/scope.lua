-- fibers/scope.lua
--
-- Stable core structured concurrency scopes that complement the Op layer.
--
-- This module provides supervision “scopes” for cooperative fibers. Scopes are
-- intended to be the unit of lifetime, cancellation and failure accounting,
-- with explicit boundaries for crossing between scopes.
--
-- Guarantees
--   * Structural lifetime: attached children are joined by the parent join,
--     including child finalisers, in attachment order.
--   * Admission gate: close() stops new spawn()/child() on the scope.
--     Joining also closes admission (but does not imply cancellation).
--   * Downward cancellation: cancel() closes admission and cascades to attached
--     children. Cancellation is a normal termination mode, distinct from failure.
--   * Fail-fast within a scope: the first non-cancellation fault marks the scope
--     failed, records a primary error, and cancels the scope to stop siblings.
--   * Join/finalisation is non-interruptible: join runs in a join worker and uses
--     op.perform_raw, so it is not interrupted by scope cancellation.
--   * Finalisers may perform only Ops that are ready now.  During finalisation,
--     scope-aware perform attempts the Op immediately and raises if it would
--     suspend.  This permits explicit try-now helpers built with or_else(),
--     while preventing hidden waits in cleanup paths.
--   * Scope-aware ops:
--       - try(ev)     -> 'ok'|'failed'|'cancelled', ...
--       - perform(ev) -> returns results on ok; raises on failed/cancelled
--                       (using a cancellation sentinel for cancelled).
--   * Boundaries (status-first, report-second):
--       - join_op() -> status, report, primary|nil
--       - run(fn, ...) -> status, report, ...          (on not-ok: ... is primary)
--       - run_op(fn, ...) -> Op yielding status, report, ... (on not-ok: ... is primary)
--
-- Notes
--   * Returning variable arity across boundaries follows Lua conventions.
--     As with any multi-return, trailing nil results are not preserved.
--
-- Deliberate non-feature
--   * No implicit upward propagation of child failure into parent failure.
--     Child outcomes are reported (via reports), not escalated.
--
---@module 'fibers.scope'

local runtime   = require 'fibers.runtime'
local waitgroup = require 'fibers.waitgroup'
local oneshot   = require 'fibers.oneshot'
local op        = require 'fibers.op'
local dlist     = require 'fibers.utils.dlist'
local safe      = require 'coxpcall'

local ok_probe, leak_probe = pcall(require, 'devicecode.support.leak_probe')
if not ok_probe then leak_probe = nil end

local DEBUG = false

--- Enable/disable debug traceback capture.
---@param v boolean
local function set_debug(v) DEBUG = not not v end

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

----------------------------------------------------------------------
-- Cancellation sentinel (robust, non-colliding)
----------------------------------------------------------------------

local CANCEL_MT = { __name = 'fibers.cancelled' }

---@class Cancelled
---@field reason any

---@param reason any
---@return Cancelled
local function cancelled(reason)
	return setmetatable({ reason = reason }, CANCEL_MT)
end

---@param err any
---@return boolean
local function is_cancelled(err)
	return type(err) == 'table' and getmetatable(err) == CANCEL_MT
end

---@param err any
---@return any|nil
local function cancel_reason(err)
	return is_cancelled(err) and err.reason or nil
end

----------------------------------------------------------------------
-- Error normalisation policy (xpcall handlers)
----------------------------------------------------------------------

local function with_tb(msg, tb)
	return DEBUG and (tb or debug.traceback(msg, 2)) or msg
end

local function tb_handler(e, tb)
	return is_cancelled(e) and e or with_tb(tostring(e), tb)
end

local function join_tb_handler(e, tb)
	return is_cancelled(e) and with_tb('join raised cancellation: ' .. tostring(cancel_reason(e)), tb)
		or with_tb(tostring(e), tb)
end

local finaliser_handler = tb_handler

local FINALISER_WAIT_ERR = 'attempted to perform a non-ready Op during scope finalisation'

----------------------------------------------------------------------
-- Types / state
----------------------------------------------------------------------

---@class ScopeChildOutcome
---@field id integer
---@field status 'ok'|'failed'|'cancelled'
---@field primary any
---@field report ScopeReport

---@class ScopeReport
---@field id integer
---@field extra_errors any[]
---@field children ScopeChildOutcome[]

---@class ScopeJoinOutcome
---@field st 'ok'|'failed'|'cancelled'
---@field primary any
---@field report ScopeReport

---@class Scope
---@field _id integer
---@field _parent Scope|nil
---@field _children table<Scope, boolean>
---@field _order Scope[]
---@field _wg Waitgroup
---@field _closed boolean
---@field _close_reason any|nil
---@field _close_os Oneshot
---@field _failed_primary any|nil   -- primary failure (string/number) if failed
---@field _cancel_reason any|nil    -- cancellation reason if cancelled
---@field _cancel_os Oneshot
---@field _extra_errors any[]
---@field _fault_os Oneshot
---@field _finalisers DList
---@field _finalising boolean
---@field _started boolean
---@field _join_started boolean
---@field _join_outcome ScopeJoinOutcome|nil
---@field _join_os Oneshot
local Scope = {}
Scope.__index = Scope

-- Weak-key map: Fiber -> Scope for attribution of uncaught runtime fiber errors.
local fiber_scopes = setmetatable({}, { __mode = 'k' })

-- Process-wide root scope.
local root_scope

-- Monotonic scope id sequence (local to the process).
local next_id = 0

local function current_fiber()
	return runtime.current_fiber()
end

----------------------------------------------------------------------
-- Unscoped error handling
----------------------------------------------------------------------

local unscoped_error_handler = function (_, err)
	io.stderr:write('Unscoped fiber error: ' .. tostring(err) .. '\n')
end

---@param handler fun(fib:any, err:any)
local function set_unscoped_error_handler(handler)
	if type(handler) ~= 'function' then error('unscoped error handler must be a function', 2) end
	unscoped_error_handler = handler
end

----------------------------------------------------------------------
-- Current scope install/restore (fiber-local only)
----------------------------------------------------------------------

local function install_current_scope(s)
	local fib = assert(current_fiber(), 'scope internal invariant violated: no current fiber')
	local prev = fiber_scopes[fib]
	fiber_scopes[fib] = s
	return fib, prev
end

local function restore_current_scope(fib, prev)
	fiber_scopes[fib] = prev
end

local function xpcall_in_scope(self, handler, f)
	local fib, prev = install_current_scope(self)
	local ok, res = safe.xpcall(f, handler)
	restore_current_scope(fib, prev)
	return ok, res
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

---@param t any[]
---@return any[]
local function copy_array(t)
	local out = {}
	for i = 1, #t do out[i] = t[i] end
	return out
end

---@param self Scope
---@return Scope[]
local function snapshot_children_set(self)
	local snap = {}
	for ch in pairs(self._children) do snap[#snap + 1] = ch end
	return snap
end

--- Build a primitive op from an oneshot-like readiness predicate.
---@param is_ready fun(): boolean
---@param os Oneshot
---@param get_values fun(): ...
---@param on_block? fun()
---@return Op
local function oneshot_value_op(is_ready, os, get_values, on_block)
	return op.new_primitive(nil, function ()
		if is_ready() then
			return true, get_values()
		end
		return false
	end, function (suspension, wrap_fn)
		local cancel = os:add_waiter(function ()
			if suspension:waiting() then suspension:complete(wrap_fn, get_values()) end
		end)
		suspension:add_cleanup(cancel)
		if on_block then on_block() end
	end)
end

---@param self Scope
---@return 'ok'|'failed'|'cancelled', any
local function terminal_status(self)
	if self._failed_primary ~= nil then return 'failed', self._failed_primary end
	if self._cancel_reason ~= nil then return 'cancelled', self._cancel_reason end
	return 'ok', nil
end

---@param self Scope
---@param child_outcomes? ScopeChildOutcome[]
---@return ScopeReport
local function make_report(self, child_outcomes)
	return {
		id           = self._id,
		extra_errors = copy_array(self._extra_errors),
		children     = child_outcomes or {},
	}
end

--- Return a rejection reason if the scope is not admitting new work; otherwise nil.
---@param self Scope
---@return string|nil
local function reject_reason(self)
	if self._join_outcome ~= nil or self._join_started then return 'scope is joining' end
	if self._failed_primary ~= nil then return 'scope has failed' end
	if self._cancel_reason ~= nil then return 'scope is cancelled' end
	if self._closed then return 'scope is closed' end
	return nil
end

----------------------------------------------------------------------
-- Observational status (non-blocking snapshot)
----------------------------------------------------------------------

---@return string st
---@return any v
function Scope:status()
	local out = self._join_outcome
	if out ~= nil then return out.st, out.primary end

	if self._failed_primary ~= nil then return 'failed', self._failed_primary end
	if self._cancel_reason ~= nil then return 'cancelled', self._cancel_reason end
	return 'running', nil
end

---@return string st
---@return any reason
function Scope:admission()
	if self._closed then return 'closed', self._close_reason end
	return 'open', nil
end

----------------------------------------------------------------------
-- Construction / root / current
----------------------------------------------------------------------

---@param parent Scope|nil
---@return Scope
local function new_scope(parent)
	next_id = next_id + 1

	local s = setmetatable({
		_id           = next_id,
		_parent       = parent,
		_children     = {},
		_extra_errors = {},
		_order        = {},
		_finalisers   = dlist.new(),
		_close_os     = oneshot.new(),
		_cancel_os    = oneshot.new(),
		_fault_os     = oneshot.new(),
		_join_os      = oneshot.new(),
		_wg           = waitgroup.new(),
	}, Scope)

	if leak_probe then leak_probe.scope_created(s._id, parent and parent._id or nil) end

	if parent then
		parent._children[s] = true
		parent._order[#parent._order + 1] = s
		if parent._cancel_reason ~= nil then s:cancel(parent._cancel_reason) end
	end

	return s
end

---@return Scope
local function root()
	if not root_scope then
		root_scope = new_scope(nil)
		runtime.spawn_raw(function ()
			while true do
				local fib, err = runtime.wait_fiber_error()
				if not is_cancelled(err) then
					local s = fiber_scopes[fib]
					if s then s:_record_fault(err) else unscoped_error_handler(fib, err) end
				end
			end
		end)
	end
	return root_scope
end

--- Return the current scope.
--- Inside a fiber: the fiber's scope, defaulting to root.
--- Outside fibers: always the root scope.
---@return Scope
local function current()
	local fib = current_fiber()
	return fib and (fiber_scopes[fib] or root()) or root()
end

----------------------------------------------------------------------
-- Child management (attachment)
----------------------------------------------------------------------

---@param self Scope
---@param child Scope
function Scope:_remove_child(child)
	if child._parent ~= self then return end
	if leak_probe then leak_probe.scope_child_detached(self._id, child._id) end
	self._children[child] = nil

	local ord = self._order
	for i = #ord, 1, -1 do
		if ord[i] == child then
			table.remove(ord, i)
			break
		end
	end

	child._parent = nil
end

function Scope:_detach_from_parent()
	local p = self._parent
	if p then p:_remove_child(self) end
end

---@return Scope|nil child, any|nil err
function Scope:child()
	local why = reject_reason(self)
	if why then return nil, why end
	return new_scope(self), nil
end

----------------------------------------------------------------------
-- Admission gate (close)
----------------------------------------------------------------------

---@param reason any|nil
function Scope:close(reason)
	if self._join_outcome then return end

	if not self._closed then
		self._closed = true
		self._close_reason = (reason ~= nil) and reason or self._close_reason
		self._close_os:signal()
		if leak_probe then leak_probe.scope_closed(self._id, self._close_reason) end
	elseif self._close_reason == nil and reason ~= nil then
		self._close_reason = reason
	end
end

---@return Op
function Scope:close_op()
	return oneshot_value_op(
		function () return self._closed end,
		self._close_os,
		function () return 'closed', self._close_reason end
	)
end

----------------------------------------------------------------------
-- Cancellation / faults
----------------------------------------------------------------------

---@param reason any|nil
function Scope:cancel(reason)
	if self._join_outcome then return end

	-- Cancellation implies admission is closed.
	self:close(reason)

	if self._cancel_reason == nil then
		self._cancel_reason = (reason ~= nil) and reason or 'scope cancelled'
		self._cancel_os:signal()
		if leak_probe then leak_probe.scope_cancelled(self._id, self._cancel_reason) end
	end

	-- Cancel attached children (snapshot avoids mutation hazards).
	local snap = snapshot_children_set(self)
	for i = 1, #snap do snap[i]:cancel(self._cancel_reason) end
end

function Scope:_record_fault(err)
	if is_cancelled(err) then
		return self:cancel(cancel_reason(err))
	end

	local e = (type(err) == 'string' or type(err) == 'number') and err or tostring(err)

	if self._failed_primary ~= nil then
		self._extra_errors[#self._extra_errors + 1] = e
		return
	end

	self._failed_primary = e
	self._fault_os:signal()

	-- single source of truth for cancellation + downward cascade
	self:cancel(e)
end

---@return Op
function Scope:cancel_op()
	return oneshot_value_op(
		function () return self._cancel_reason ~= nil end,
		self._cancel_os,
		function () return 'cancelled', self._cancel_reason end
	)
end

---@return Op
function Scope:fault_op()
	return oneshot_value_op(
		function () return self._failed_primary ~= nil end,
		self._fault_os,
		function () return 'failed', self._failed_primary end
	)
end

---@return Op
function Scope:not_ok_op()
	return op.choice(self:fault_op(), self:cancel_op()):wrap(function ()
		if self._failed_primary ~= nil then return 'failed', self._failed_primary end
		return 'cancelled', self._cancel_reason
	end)
end

----------------------------------------------------------------------
-- Finalisers
----------------------------------------------------------------------

---@param f fun(aborted:boolean, status:'ok'|'failed'|'cancelled', primary:any|nil)
---@return fun() detach
function Scope:finally(f)
	if type(f) ~= 'function' then error('scope:finally expects a function', 2) end

	local fib = current_fiber()
	if not fib then error('scope:finally must be called from inside a fiber', 2) end

	local cur = fiber_scopes[fib] or root()
	if self._started and cur ~= self then
		error('once started scope:finally must be called from within the target scope', 2)
	end

	if self._finalising or self._join_outcome ~= nil then
		error('scope:finally: scope is finalising or has joined', 2)
	end

	local node = self._finalisers:push_tail(f)
	if leak_probe then leak_probe.scope_finalizer_added(self._id) end
	local detached = false
	return function ()
		if detached then return false end
		detached = true
		local removed = node:remove()
		if removed and leak_probe then leak_probe.scope_finalizer_removed(self._id, 'detach') end
		return removed
	end
end

----------------------------------------------------------------------
-- Spawning (attached obligations)
----------------------------------------------------------------------

---@param fn fun(s:Scope, ...): any
---@param ... any
---@return boolean ok, any|nil err
function Scope:spawn(fn, ...)
	local why = reject_reason(self)
	if why then return false, why end

	-- From this point, treat the scope as having started work.
	self._started = true
	if leak_probe then leak_probe.scope_spawned(self._id) end

	local args = pack(...)
	self._wg:add(1)

	runtime.spawn_raw(function ()
		local ok, err = xpcall_in_scope(self, tb_handler, function ()
			return fn(self, unpack(args, 1, args.n))
		end)
		if not ok then self:_record_fault(err) end
		self._wg:done()
	end)

	return true, nil
end

----------------------------------------------------------------------
-- Join (non-interruptible finalisation)
----------------------------------------------------------------------

---@param self Scope
---@return ScopeChildOutcome[]
function Scope:_finalise_join_body()
	self:close('joining')

	local children = copy_array(self._order)
	local child_outcomes = {}

	op.perform_raw(self._wg:wait_op())

	for i = 1, #children do
		local ch = children[i]
		if ch and ch._parent == self then
			local st, rep, primary = op.perform_raw(ch:join_op())
			child_outcomes[#child_outcomes + 1] = {
				id      = ch._id,
				status  = st,
				primary = primary,
				report  = rep,
			}
			self:_remove_child(ch)
		end
	end

	local st, primary = terminal_status(self)
	local aborted = (st ~= 'ok')

	-- Freeze finaliser registration at the start of finalisation.
	self._finalising = true

	local node = self._finalisers.tail
	while node do
		local prev = node.prev
		local f = node.value
		if node:remove() and leak_probe then leak_probe.scope_finalizer_removed(self._id, 'run') end -- ensure it cannot be run twice, and drop refs early

		if f then
			local ok, err = safe.xpcall(function ()
				return f(aborted, st, primary)
			end, finaliser_handler)

			if not ok then
				if is_cancelled(err) then
					self:_record_fault('finaliser raised cancellation: ' .. tostring(cancel_reason(err)))
				else
					self:_record_fault(err)
				end
				st, primary = terminal_status(self)
				aborted = (st ~= 'ok')
			end
		end

		node = prev
	end

	return child_outcomes
end

function Scope:_start_join_worker()
	if self._join_started then return end
	self._started = true
	self._join_started = true
	if leak_probe then leak_probe.scope_join_started(self._id) end

	runtime.spawn_raw(function ()
		local child_outcomes
		local ok, err = xpcall_in_scope(self, join_tb_handler, function ()
			child_outcomes = self:_finalise_join_body()
		end)
		if not ok then self:_record_fault(err) end

		local st, primary = terminal_status(self)
		local rep = make_report(self, child_outcomes or {})

		self._join_outcome = { st = st, primary = primary, report = rep }
		if leak_probe then leak_probe.scope_join_done(self._id, st) end
		self._join_os:signal()
		self:_detach_from_parent()
	end)
end

---@return Op
function Scope:join_op()
	return oneshot_value_op(
		function () return self._join_outcome ~= nil end,
		self._join_os,
		function ()
			local out = assert(self._join_outcome, 'join signalled without outcome')
			return out.st, out.report, out.primary
		end,
		function () self:_start_join_worker() end
	)
end

----------------------------------------------------------------------
-- Scope-aware op performance (status-first)
----------------------------------------------------------------------

---@param ev any
local function assert_op_value(ev)
	if type(ev) ~= 'table' or getmetatable(ev) ~= op.Op then
		error(('scope: expected op, got %s (%s)'):format(type(ev), tostring(ev)), 3)
	end
end

---@param ev Op
---@return Op
local function finalising_try_op(ev)
	-- Finalisers run after the scope is already failed, cancelled or joining.  They
	-- still need to be able to use explicit immediate attempts such as:
	--
	--   tx:send_op(value):or_else(function () return nil, 'not_ready' end)
	--
	-- but finalisation must not hide a suspension.  or_else performs only the
	-- Op's readiness probe and chooses the fallback if it would block.  For
	-- composite Ops this also triggers losing-arm nacks/abort handlers, which is
	-- the right cleanup behaviour for an attempted synchronisation that did not
	-- commit.
	return ev:wrap(function (...)
		return 'ok', ...
	end):or_else(function ()
		return 'failed', FINALISER_WAIT_ERR
	end)
end

---@param ev Op
---@return Op
function Scope:try_op(ev)
	assert_op_value(ev)

	return op.guard(function ()
		if self._finalising then
			return finalising_try_op(ev)
		end

		if self._failed_primary ~= nil then return op.always('failed', self._failed_primary) end
		if self._cancel_reason ~= nil then return op.always('cancelled', self._cancel_reason) end

		local body = ev:wrap(function (...)
			if self._failed_primary ~= nil then return 'failed', self._failed_primary end
			if self._cancel_reason ~= nil then return 'cancelled', self._cancel_reason end
			return 'ok', ...
		end)

		return op.choice(body, self:not_ok_op())
	end)
end

---@param ev Op
---@return 'ok'|'failed'|'cancelled', ...
function Scope:try(ev)
	if not current_fiber() then error('scope:try must be called from inside a fiber', 2) end
	return op.perform_raw(self:try_op(ev))
end

---@param ev Op
---@return any ...
function Scope:perform(ev)
	local r = pack(self:try(ev))
	local st = r[1]
	if st == 'ok' then return unpack(r, 2, r.n) end
	if st == 'cancelled' then error(cancelled(r[2]), 0) end
	error(r[2] or 'scope failed', 0)
end

----------------------------------------------------------------------
-- Boundaries
----------------------------------------------------------------------

---@param body_fn fun(s:Scope, ...): ...
---@param ... any
---@return Op
local function run_op(body_fn, ...)
	if type(body_fn) ~= 'function' then error('scope.run_op expects a function', 2) end

	local args = pack(...)

	return op.guard(function ()
		local parent = current()

		-- Admission fast path: return an already-ready op.
		local why = reject_reason(parent)
		if why then return op.always('cancelled', make_report(parent, {}), why) end

		-- Per-perform state (initially unset).
		local child, child_err, results

		local function start_once()
			if child ~= nil or child_err ~= nil then return end

			child, child_err = parent:child()
			if not child then return end

			local ok_spawn, spawn_err = child:spawn(function (s)
				local ok, err = safe.xpcall(function ()
					results = pack(body_fn(s, unpack(args, 1, args.n)))
				end, tb_handler)

				if not ok then s:_record_fault(err) end

				s:close('body complete')
				s:_start_join_worker()
			end)

			if not ok_spawn then
				child:_record_fault(spawn_err)
				child:close('body spawn failed')
				child:_start_join_worker()
			end
		end

		local function complete_from_join(suspension, wrap_fn)
			local out = assert(child and child._join_outcome,
				'scope violated: child join signalled without outcome')

			if out.st == 'ok' then
				local r = results or pack()
				suspension:complete(wrap_fn, 'ok', out.report, unpack(r, 1, r.n))
			else
				suspension:complete(wrap_fn, out.st, out.report, out.primary)
			end
		end

		local function try_fn() return false end

		local function block_fn(suspension, wrap_fn)
			start_once()

			if not child then
				suspension:complete(wrap_fn, 'cancelled', make_report(parent, {}), child_err)
				return
			end

			local cancel_join = child._join_os:add_waiter(function ()
				if suspension:waiting() then complete_from_join(suspension, wrap_fn) end
			end)
			suspension:add_cleanup(cancel_join)

			if child._join_outcome and suspension:waiting() then
				complete_from_join(suspension, wrap_fn)
			end
		end

		local ev = op.new_primitive(nil, try_fn, block_fn)

		return ev:on_abort(function ()
			if not child then return end

			child:cancel('aborted')
			child:_start_join_worker()
			safe.pcall(function () op.perform_raw(child:join_op()) end)
		end)
	end)
end

---@param body_fn fun(s:Scope, ...): ...
---@param ... any
---@return 'ok'|'failed'|'cancelled', ScopeReport, any ...
local function run(body_fn, ...)
	if type(body_fn) ~= 'function' then error('scope.run expects a function body', 2) end
	if not current_fiber() then error('scope.run must be called from inside a fiber', 2) end
	return op.perform_raw(run_op(body_fn, ...))
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	root    = root,
	current = current,
	Scope   = Scope,

	run    = run,
	run_op = run_op,

	cancelled     = cancelled,
	is_cancelled  = is_cancelled,
	cancel_reason = cancel_reason,

	set_debug = set_debug,

	set_unscoped_error_handler = set_unscoped_error_handler,
}
