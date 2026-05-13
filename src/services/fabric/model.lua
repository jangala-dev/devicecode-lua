-- services/fabric/model.lua
--
-- Fabric observable models and retained snapshot helpers.
--
-- The generic observable model mechanics live in devicecode.support.model.  This
-- module keeps only Fabric's default shallow copy/equality policy and public
-- service namespace.

local base_model = require 'devicecode.support.model'
local tablex     = require 'shared.table'

local M = {}

local function default_copy(v)
	if type(v) == 'table' then
		return tablex.shallow_copy(v)
	end
	return v
end

local function default_equals(a, b)
	if rawequal(a, b) then return true end
	if type(a) ~= type(b) then return false end
	if type(a) ~= 'table' then return a == b end
	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

function M.new(initial, opts)
	opts = opts or {}
	return base_model.new(initial, {
		copy = opts.copy or default_copy,
		equals = opts.equals or default_equals,
		label = opts.label or 'fabric.model',
	})
end

M.Model = base_model.Model

return M
