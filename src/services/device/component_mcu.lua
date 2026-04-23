-- services/device/component_mcu.lua
--
-- MCU-specific fact composition.

local model = require 'services.device.model'
local schema = require 'services.device.schemas.mcu'
local availability = require 'services.device.availability'

local M = {}

local function copy(v)
	return model.copy_value(v)
end

local function ensure_table(v)
	return type(v) == 'table' and v or {}
end

function M.empty()
	return {
		available = false,
		ready = false,
		software = {},
		updater = {},
		capabilities = {},
		source = {},
		health = nil,
		events = {},
		raw = {},
	}
end

local function normalize_software_fact(raw)
	return schema.normalize_software(raw)
end

local function normalize_updater_fact(raw)
	return schema.normalize_updater(raw)
end

local function normalize_health_fact(raw)
	return schema.normalize_health(raw)
end

function M.compose(raw_facts, fact_state)
	raw_facts = type(raw_facts) == 'table' and raw_facts or {}
	fact_state = type(fact_state) == 'table' and fact_state or {}

	local software_raw = raw_facts.software
	local updater_raw = raw_facts.updater
	local health_raw = raw_facts.health

	local status = availability.source_status({ fact_state = fact_state, raw_facts = raw_facts }, { required_facts = { 'software', 'updater' } })
	local software = normalize_software_fact(software_raw)
	local updater = normalize_updater_fact(updater_raw)
	local health = normalize_health_fact(health_raw)

	return {
		available = status.available,
		ready = status.ready,
		software = software,
		updater = updater,
		health = health,
		capabilities = {},
		source = {
			kind = 'member',
		},
		events = {},
		raw = {
			software = copy(software_raw),
			updater = copy(updater_raw),
			health = copy(health_raw),
		},
	}
end

return M
