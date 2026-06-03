-- fibers/cond.lua
---
-- Generic condition operations built on top of oneshot and op.
-- A condition can be waited on via an Op or by blocking in the current fiber.
---@module 'fibers.cond'

local op      = require 'fibers.op'
local oneshot = require 'fibers.oneshot'
local perform = require 'fibers.performer'.perform

--- Condition variable backed by a one-shot.
---@class Cond
---@field _os Oneshot
local Cond = {}
Cond.__index = Cond

--- Build an Op that becomes ready when the condition fires.
---@return Op
function Cond:wait_op()
	local os = self._os

	return op.new_primitive(
		nil,
		function ()
			return os:is_triggered()
		end,
		--- Arrange to complete this suspension when the condition fires.
		---@param resumer Suspension
		---@param wrap_fn WrapFn
		function (resumer, wrap_fn)
			local cancel = os:add_waiter(function ()
				if resumer:waiting() then
					resumer:complete(wrap_fn)
				end
			end)
			-- ensure the waiter closure does not remain referenced if the wait is cancelled
			resumer:add_cleanup(cancel)
		end
	)
end

--- Block the current fiber until the condition fires.
---@return any ...
function Cond:wait()
	return perform(self:wait_op())
end

--- Signal the condition (idempotent).
function Cond:signal()
	return self._os:signal()
end

--- Create a new condition.
---@return Cond
local function new()
	return setmetatable({
		_os = oneshot.new(), -- no extra callback
	}, Cond)
end

return {
	new = new,
}
