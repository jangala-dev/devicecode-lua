-- fibers/io/poller/core.lua
--
-- Core glue for poller backends.
--
-- This module owns the public Poller shape and semantics.
-- Platform backends provide only low-level primitives; build_poller
-- wires those into a concrete { get, Poller, is_supported } module.
--
-- Backend ops contract:
--   ops.new_backend() -> backend_state
--   ops.poll(backend_state, timeout_ms, rd_waitset, wr_waitset) -> events
--       events is a table: events[fd] = { rd = bool, wr = bool, err = bool }
--   ops.on_wait_change(backend_state, fd, want_rd, want_wr)     -- optional
--   ops.close_backend(backend_state)                            -- optional
--   ops.is_supported() -> boolean                               -- optional
--
---@module 'fibers.io.poller.core'

local runtime = require 'fibers.runtime'
local wait    = require 'fibers.wait'

---@class Poller : TaskSource
---@field backend_state any
---@field rd Waitset
---@field wr Waitset
---@field _ops table
local Poller = {}
Poller.__index = Poller

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

local function recompute_mask(self, fd)
	local ops = self._ops
	if not ops.on_wait_change then
		return
	end
	local want_rd = not self.rd:is_empty(fd)
	local want_wr = not self.wr:is_empty(fd)
	ops.on_wait_change(self.backend_state, fd, want_rd, want_wr)
end

local function seconds_to_ms(timeout)
	if timeout == nil then
		-- Non-blocking poll.
		return 0
	elseif timeout < 0 then
		-- “Infinite” block.
		return -1
	else
		return math.floor(timeout * 1e3 + 0.5)
	end
end

----------------------------------------------------------------------
-- Public methods
----------------------------------------------------------------------

--- Register a task as waiting on an fd for read or write readiness.
---@param fd integer
---@param dir '"rd"'|'"wr"'
---@param task Task
---@return WaitToken
function Poller:wait(fd, dir, task)
	-- assert(type(fd) == "number", "fd must be number")
	assert(fd ~= nil, 'fd must be non-nil')
	assert(dir == 'rd' or dir == 'wr', "dir must be 'rd' or 'wr'")

	local ws    = (dir == 'rd') and self.rd or self.wr
	local token = ws:add(fd, task)

	-- Update backend subscription / mask.
	recompute_mask(self, fd)

	-- Wrap unlink to keep backend state in sync with waitsets.
	local original_unlink = token.unlink
	local owner           = self

	function token.unlink(tok)
		local emptied = original_unlink(tok)
		if emptied then
			recompute_mask(owner, fd)
		end
		return emptied
	end

	return token
end

--- TaskSource hook: wait for events and schedule ready tasks.
---@param sched Scheduler
---@param _ number|nil        -- current monotonic time (unused)
---@param timeout number|nil  -- seconds
function Poller:schedule_tasks(sched, _, timeout)
	local ops = self._ops

	local timeout_ms = seconds_to_ms(timeout)
	local events     = ops.poll(self.backend_state, timeout_ms, self.rd, self.wr)
	if not events then
		-- Backend chose to do nothing (e.g. no fds registered).
		return
	end

	for fd, flags in pairs(events) do
		if flags.rd or flags.err then
			self.rd:notify_all(fd, sched)
		end
		if flags.wr or flags.err then
			self.wr:notify_all(fd, sched)
		end

		-- Re-arm / update backend subscription after delivering events.
		recompute_mask(self, fd)
	end
end

-- Used by the scheduler.
Poller.wait_for_events = Poller.schedule_tasks

function Poller:close()
	if self.backend_state and self._ops.close_backend then
		self._ops.close_backend(self.backend_state)
	end
	self.backend_state = nil
end

----------------------------------------------------------------------
-- Builder
----------------------------------------------------------------------

--- Build a concrete poller module from low-level ops.
---
--- See top-of-file comment for ops contract.
---
---@param ops table
---@return table poller_module  -- { get = fn, Poller = Poller, is_supported = fn }
local function build_poller(ops)
	assert(type(ops) == 'table', 'poller ops must be a table')
	assert(type(ops.new_backend) == 'function', 'ops.new_backend must be a function')
	assert(type(ops.poll) == 'function', 'ops.poll must be a function')

	local function new_poller()
		local backend_state = ops.new_backend()
		local self = {
			backend_state = backend_state,
			rd            = wait.new_waitset(),
			wr            = wait.new_waitset(),
			_ops          = ops,
		}
		return setmetatable(self, Poller)
	end

	local singleton

	local function get()
		if singleton then
			return singleton
		end
		singleton = new_poller()
		local sched = runtime.current_scheduler
		assert(sched.add_task_source, 'scheduler must implement add_task_source')
		sched:add_task_source(singleton)
		return singleton
	end

	local function is_supported()
		if type(ops.is_supported) == 'function' then
			return not not ops.is_supported()
		end
		return true
	end

	return {
		get          = get,
		Poller       = Poller,
		is_supported = is_supported,
	}
end

return {
	build_poller = build_poller,
}
