-- services/device/component_mcu.lua
-- Pure MCU component normalisation, action description, and availability overlay.

local schema = require 'services.device.schemas.mcu'
local model  = require 'services.device.model'

local M = { kind = 'mcu' }

local function copy(v)
	return model.copy_value(v)
end

function M.normalise_fact(fact, raw)
	if fact == 'software' then return schema.normalise_software(raw), nil end
	if fact == 'updater' then return schema.normalise_updater(raw), nil end
	if fact == 'health' then return schema.normalise_health(raw), nil end
	if fact == 'charger_alert' then return schema.normalise_charger_alert(raw), nil end
	return copy(raw), nil
end
function M.normalise_event(event, raw)
	if event == 'charger_alert' then return schema.normalise_charger_alert(raw), nil end
	return copy(raw), nil
end
function M.compose(raw_facts, raw_events)
	return schema.compose(raw_facts, raw_events)
end

function M.action_spec(_, _, _, base_spec)
	return copy(base_spec), nil
end

function M.availability(base, rec)
	local out = copy(base)
	local facts = type(rec) == 'table' and rec.raw_facts or {}
	local boot = type(facts) == 'table' and facts.boot or nil
	local health = type(facts) == 'table' and facts.health or nil

	if type(boot) == 'table' and boot.mode == 'bootloader' and out.availability == 'available' then
		out.availability = 'degraded'
		out.health = 'warning'
		out.reason = 'bootloader_mode'
	end

	local health_state = schema.normalise_health(health)
	if health_state == 'failed' then
		out.availability = 'unavailable'
		out.health = 'fault'
		out.reason = 'mcu_fault'
	elseif health_state == 'degraded' and out.availability == 'available' then
		out.availability = 'degraded'
		out.health = 'warning'
		out.reason = 'mcu_degraded'
	end

	return out
end

return M
