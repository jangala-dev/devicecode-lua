local pulse = require 'fibers.pulse'

local M = {}
M.__index = M

function M.new()
    return setmetatable({
        changed = pulse.scoped({ close_reason = 'update observer stopping' }),
        components = {},
    }, M)
end

function M.version(self)
    return self.changed:version()
end

function M.changed_op(self, last_seen)
    return self.changed:changed_op(last_seen)
end

function M.note_component(self, name, payload)
    if type(name) ~= 'string' or name == '' then return end
    self.components[name] = payload
    self.changed:signal()
end

function M.clear_component(self, name)
    if type(name) ~= 'string' or name == '' then return end
    self.components[name] = nil
    self.changed:signal()
end

function M.facts_for(self, name)
    return self.components[name]
end

return M
