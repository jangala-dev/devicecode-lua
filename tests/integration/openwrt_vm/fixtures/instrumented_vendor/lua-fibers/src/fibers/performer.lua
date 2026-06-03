-- fibers/performer.lua
---
-- Scope-aware performer for ops.
-- Preferred entry point for synchronising on ops in normal code.
-- Delegates to the current scope if available, otherwise falls back
-- to the raw op.perform.
---@module 'fibers.performer'

local Op      = require 'fibers.op'
local Runtime = require 'fibers.runtime'

---@type any
local scope_mod

--- Get the current scope if the scope module has been loaded.
---@return Scope|nil
local function current_scope()
	if not scope_mod then
		scope_mod = require 'fibers.scope'
	end
	return scope_mod.current and scope_mod.current() or nil
end

--- Check that a value is an Op instance.
---@param op any
local function assert_op(op)
	if type(op) ~= 'table' or getmetatable(op) ~= Op.Op then
		error(('perform: expected op, got %s (%s)'):format(type(op), tostring(op)), 3)
	end
end

--- Perform an op under the current scope, if any.
--- Must be called from inside a fiber.
---@param op Op
---@return any ...
local function perform(op)
	if not Runtime.current_fiber() then error('perform be called from inside a fiber', 2) end
	assert_op(op)

	local s = current_scope()
	if s and s.perform then
		return s:perform(op)
	else
		return Op.perform_raw(op)
	end
end

return {
	perform = perform,
}
