-- services/update/observe.lua
--
-- Small retained-state observer cache for reconcile.
--
-- Responsibilities:
--   * remember latest component facts by component name
--   * provide a pulse for change-driven waiting
--   * expose the minimal interface needed by await/runner

local pulse = require 'fibers.pulse'

local M = {}
local Observe = {}
Observe.__index = Observe

function M.new()
	return setmetatable({
		changed = pulse.scoped({ close_reason = 'update observer stopping' }),
		components = {},
	}, Observe)
end

function Observe:version()
	return self.changed:version()
end

function Observe:changed_op(last_seen)
	return self.changed:changed_op(last_seen)
end

function Observe:note_component(name, payload)
	if type(name) ~= 'string' or name == '' then return end
	self.components[name] = payload
	self.changed:signal()
end

function Observe:clear_component(name)
	if type(name) ~= 'string' or name == '' then return end
	self.components[name] = nil
	self.changed:signal()
end

function Observe:component_state_for(name)
	return self.components[name]
end

return M
