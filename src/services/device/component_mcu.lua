-- services/device/component_mcu.lua
-- Pure MCU component normalisation, action description, and availability overlay.

local schema = require 'services.device.schemas.mcu'
local model  = require 'services.device.model'

local M = { kind = 'mcu' }

local function copy(v)
	return model.copy_value(v)
end

function M.normalize_fact(fact, raw)
	if fact == 'software' then return schema.normalize_software(raw), nil end
	if fact == 'updater' then return schema.normalize_updater(raw), nil end
	if fact == 'health' then
		if type(raw) == 'table' then
			return {
				health = raw.health or raw.state or raw.status or raw.kind,
				fault = raw.fault,
				fault_code = raw.fault_code,
				error = raw.error or raw.err,
				details = copy(raw.details),
			}, nil
		end
		return schema.normalize_health(raw), nil
	end
	if fact == 'charger_alert' then return schema.normalize_charger_alert(raw), nil end
	return copy(raw), nil
end
M.normalise_fact = M.normalize_fact

function M.normalize_event(event, raw)
	if event == 'charger_alert' then return schema.normalize_charger_alert(raw), nil end
	return copy(raw), nil
end
M.normalise_event = M.normalize_event

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

	if type(health) == 'table' then
		local fault = health.fault_code or health.fault or health.error or health.err
		if fault ~= nil and fault ~= false then
			out.availability = 'unavailable'
			out.health = 'fault'
			out.reason = 'mcu_fault'
		end
	elseif type(health) == 'string' and (health == 'fault' or health == 'failed' or health == 'error') then
		out.availability = 'unavailable'
		out.health = 'fault'
		out.reason = 'mcu_fault'
	end

	return out
end

return M
