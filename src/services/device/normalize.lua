-- services/device/normalize.lua
--
-- Public-status normalisation for fact-backed device components.

local component_mcu = require 'services.device.component_mcu'
local component_host = require 'services.device.component_host'
local model = require 'services.device.model'

local M = {}

function M.normalize_component(rec)
	local subtype = type(rec) == 'table' and (rec.subtype or rec.member_class or rec.name) or nil

	if not model.has_facts(rec) then
		error('device component is not fact-backed: ' .. tostring(subtype or 'unknown'), 0)
	end

	if subtype == 'mcu' then
		return component_mcu.compose(rec.raw_facts or {}, rec.fact_state or {})
	end

	return component_host.compose(rec.raw_facts or {}, rec.fact_state or {})
end

return M
