-- services/device/schemas/mcu.lua
--
-- Canonical MCU fact/event names and lightweight payload normalisation.
-- This module deliberately owns names and field spellings only; component
-- composition remains in component_mcu.lua.

local topics = require 'services.device.topics'

local M = {}

M.fact_names = {
	software = 'software',
	updater = 'updater',
	health = 'health',
	power_battery = 'power_battery',
	power_charger = 'power_charger',
	power_charger_config = 'power_charger_config',
	environment_temperature = 'environment_temperature',
	environment_humidity = 'environment_humidity',
	runtime_memory = 'runtime_memory',
}

M.event_names = {
	charger_alert = 'charger_alert',
}

M.alert_kinds = {
	vin_lo = true,
	vin_hi = true,
	bsr_high = true,
	bat_missing = true,
	bat_short = true,
	max_charge_time_fault = true,
	absorb = true,
	equalize = true,
	cccv = true,
	precharge = true,
	iin_limited = true,
	uvcl_active = true,
	cc_phase = true,
	cv_phase = true,
}

function M.member_fact_topics(member)
	member = member or 'mcu'
	return {
		software = topics.member_state(member, 'software'),
		updater = topics.member_state(member, 'updater'),
		health = topics.member_state(member, 'health'),
		power_battery = topics.member_state(member, 'power', 'battery'),
		power_charger = topics.member_state(member, 'power', 'charger'),
		power_charger_config = topics.member_state(member, 'power', 'charger', 'config'),
		environment_temperature = topics.member_state(member, 'environment', 'temperature'),
		environment_humidity = topics.member_state(member, 'environment', 'humidity'),
		runtime_memory = topics.member_state(member, 'runtime', 'memory'),
	}
end

function M.member_event_topics(member)
	member = member or 'mcu'
	return {
		charger_alert = topics.member_event(member, 'power', 'charger', 'alert'),
	}
end

local function table_or_empty(v)
	return type(v) == 'table' and v or {}
end

function M.normalize_software(raw)
	raw = table_or_empty(raw)
	return {
		version = raw.version or raw.fw_version or nil,
		build = raw.build or nil,
		image_id = raw.image_id or nil,
		boot_id = raw.boot_id or nil,
	}
end

function M.normalize_updater(raw)
	raw = table_or_empty(raw)
	return {
		state = raw.state or raw.status or raw.kind or nil,
		last_error = raw.last_error or raw.err or nil,
		pending_version = raw.pending_version or nil,
	}
end

function M.normalize_health(raw)
	raw = table_or_empty(raw)
	if raw.state ~= nil then return raw.state end
	if raw.health ~= nil then return raw.health end
	if next(raw) ~= nil then return 'ok' end
	return nil
end

return M
