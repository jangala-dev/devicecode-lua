-- services/update/observe.lua
--
-- Small retained-state observer cache for reconcile.
--
-- Responsibilities:
--   * remember latest component facts by component name
--   * stay usable from plain unit tests outside fibers
--   * delegate change signalling to the owning runtime/service

local M = {}
local Observe = {}
Observe.__index = Observe

local function deep_equal(a, b, seen)
	if a == b then return true end
	if type(a) ~= type(b) then return false end
	if type(a) ~= 'table' then return false end
	seen = seen or {}
	seen[a] = seen[a] or {}
	if seen[a][b] then return true end
	seen[a][b] = true
	for k, v in pairs(a) do
		if not deep_equal(v, b[k], seen) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function note_changed(self)
	self._version = self._version + 1
	local cb = self._on_change
	if type(cb) == 'function' then cb(self._version) end
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_version = 0,
		_on_change = opts.on_change,
		components = {},
	}, Observe)
end

function Observe:version()
	return self._version
end

function Observe:note_component(name, payload)
	if type(name) ~= 'string' or name == '' then return end
	if deep_equal(self.components[name], payload) then return end
	self.components[name] = payload
	note_changed(self)
end

function Observe:clear_component(name)
	if type(name) ~= 'string' or name == '' then return end
	if self.components[name] == nil then return end
	self.components[name] = nil
	note_changed(self)
end

function Observe:component_state_for(name)
	return self.components[name]
end

return M
