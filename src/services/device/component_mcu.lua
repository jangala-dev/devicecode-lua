-- services/device/component_mcu.lua
--
-- MCU-specific fact/event composition.

local model = require 'services.device.model'
local schema = require 'services.device.schemas.mcu'
local availability = require 'services.device.availability'

local M = {}

local function copy(v)
	return model.copy_value(v)
end

local function non_empty_or_nil(t)
	return type(t) == 'table' and next(t) ~= nil and t or nil
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
		power = {},
		environment = {},
		runtime = {},
		alerts = {},
		events = {},
		raw = {},
	}
end

function M.compose(raw_facts, fact_state, raw_events, event_state)
	raw_facts = type(raw_facts) == 'table' and raw_facts or {}
	fact_state = type(fact_state) == 'table' and fact_state or {}
	raw_events = type(raw_events) == 'table' and raw_events or {}
	event_state = type(event_state) == 'table' and event_state or {}

	local software_raw = raw_facts.software
	local updater_raw = raw_facts.updater
	local health_raw = raw_facts.health
	local battery_raw = raw_facts.power_battery
	local charger_raw = raw_facts.power_charger
	local charger_config_raw = raw_facts.power_charger_config
	local temperature_raw = raw_facts.environment_temperature
	local humidity_raw = raw_facts.environment_humidity
	local memory_raw = raw_facts.runtime_memory
	local charger_alert_raw = raw_events.charger_alert

	local status = availability.source_status({
		fact_state = fact_state,
		event_state = event_state,
		source_up = true,
	}, { required_facts = { 'software', 'updater' } })

	local software = schema.normalize_software(software_raw)
	local updater = schema.normalize_updater(updater_raw)
	local health = schema.normalize_health(health_raw)
	local battery = schema.normalize_battery(battery_raw)
	local charger = schema.normalize_charger(charger_raw)
	local charger_config = schema.normalize_charger_config(charger_config_raw)
	local temperature = schema.normalize_temperature(temperature_raw)
	local humidity = schema.normalize_humidity(humidity_raw)
	local memory = schema.normalize_runtime_memory(memory_raw)
	local last_charger_alert = schema.normalize_charger_alert(charger_alert_raw)

	local alerts = {}
	if last_charger_alert.kind ~= nil then
		alerts.charger_alert = last_charger_alert
	end

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
		power = {
			battery = non_empty_or_nil(battery),
			charger = non_empty_or_nil(charger),
			charger_config = non_empty_or_nil(charger_config),
		},
		environment = {
			temperature = non_empty_or_nil(temperature),
			humidity = non_empty_or_nil(humidity),
		},
		runtime = {
			memory = non_empty_or_nil(memory),
		},
		alerts = alerts,
		events = copy(raw_events),
		event_state = copy(event_state),
		raw = {
			software = copy(software_raw),
			updater = copy(updater_raw),
			health = copy(health_raw),
			power_battery = copy(battery_raw),
			power_charger = copy(charger_raw),
			power_charger_config = copy(charger_config_raw),
			environment_temperature = copy(temperature_raw),
			environment_humidity = copy(humidity_raw),
			runtime_memory = copy(memory_raw),
		},
	}
end

return M
