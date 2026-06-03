-- fibers/waitgroup.lua
---
-- Wait group for tracking completion of a set of tasks.
-- A waitgroup supports generations: when the counter returns to zero,
-- the current generation completes and a new one starts on the next increment.
---@module 'fibers.waitgroup'

local op       = require 'fibers.op'
local perform  = require 'fibers.performer'.perform
local cond_mod = require 'fibers.cond'

--- Waitgroup with a counter and per-generation condition.
---@class Waitgroup
---@field _counter integer
---@field _cond Cond|nil  # per-generation condition; nil when there is no active generation
local Waitgroup = {}
Waitgroup.__index = Waitgroup

--- Create a new waitgroup.
---@return Waitgroup
local function new()
	return setmetatable({
		_counter = 0,
		_cond    = nil, -- per-generation condition; nil when idle
	}, Waitgroup)
end

--- Adjust the waitgroup counter by delta.
--- When the counter returns to zero, the current generation completes.
---@param delta integer
function Waitgroup:add(delta)
	if delta == 0 then
		return
	end

	local old_count = self._counter
	local new_count = old_count + delta

	if new_count < 0 then
		error('waitgroup counter goes negative')
	end

	self._counter = new_count

	if new_count == 0 then
		-- This generation completes: wake any waiters and drop the condition.
		if self._cond then
			self._cond:signal()
			self._cond = nil
		end
	elseif old_count == 0 and new_count > 0 then
		-- Starting a new generation: create a condition for new work.
		self._cond = cond_mod.new()
	end
end

--- Decrement the waitgroup counter by one.
function Waitgroup:done()
	self:add(-1)
end

--- Build an Op that completes when the current generation drains.
---@return Op
function Waitgroup:wait_op()
	-- Build the op lazily at perform time.
	return op.guard(function ()
		-- If there is nothing outstanding, fire immediately.
		if self._counter == 0 then
			return op.always()
		end

		-- Active generation: delegate to the generation's condition.
		local cond = assert(self._cond, 'waitgroup internal error: missing condition for active generation')
		return cond:wait_op()
	end)
end

--- Block until the current generation completes.
---@return any ...
function Waitgroup:wait()
	return perform(self:wait_op())
end

return {
	--- Construct a new waitgroup.
	---@return Waitgroup
	new = new,
}
