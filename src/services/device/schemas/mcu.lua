-- services/device/schemas/mcu.lua
-- Pure MCU schema helpers.

local topics = require 'services.device.topics'
local model  = require 'services.device.model'

local M = {}

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
		software = topics.raw_member_state(member, 'software'),
		updater = topics.raw_member_state(member, 'updater'),
		health = topics.raw_member_state(member, 'health'),
		power_battery = topics.raw_member_state(member, 'power', 'battery'),
		power_charger = topics.raw_member_state(member, 'power', 'charger'),
		power_charger_config = topics.raw_member_state(member, 'power', 'charger', 'config'),
		environment_temperature = topics.raw_member_state(member, 'environment', 'temperature'),
		environment_humidity = topics.raw_member_state(member, 'environment', 'humidity'),
		runtime_memory = topics.raw_member_state(member, 'runtime', 'memory'),
	}
end

function M.member_event_topics(member)
	member = member or 'mcu'
	return {
		charger_alert = topics.raw_member_cap_event(member, 'telemetry', 'main', 'power', 'charger', 'alert'),
	}
end

local function table_or_empty(v)
	return type(v) == 'table' and v or {}
end

local function copy(v)
	return model.copy_value(v)
end

local function copy_named(raw, names)
	local out = {}
	raw = table_or_empty(raw)
	for i = 1, #names do
		local name = names[i]
		if raw[name] ~= nil then out[name] = raw[name] end
	end
	return out
end

function M.normalise_software(raw)
	raw = table_or_empty(raw)
	return {
		version = raw.version,
		build_id = raw.build_id,
		image_id = raw.image_id,
		boot_id = raw.boot_id,
		payload_sha256 = raw.payload_sha256,
	}
end

function M.normalise_updater(raw)
	raw = table_or_empty(raw)
	return {
		state = raw.state,
		last_error = raw.last_error,
		pending_version = raw.pending_version,
		pending_image_id = raw.pending_image_id,
		staged_image_id = raw.staged_image_id,
		job_id = raw.job_id,
		boot_buy_rc = raw.boot_buy_rc,
	}
end

function M.normalise_health(raw)
	if type(raw) == 'string' then return raw end
	raw = table_or_empty(raw)
	if raw.state ~= nil then return raw.state end
	if next(raw) ~= nil then return 'ok' end
	return nil
end

function M.normalise_charger_alert(raw)
	raw = table_or_empty(raw)
	local kind = raw.kind
	return {
		kind = type(kind) == 'string' and kind or nil,
		known = type(kind) == 'string' and M.alert_kinds[kind] == true or false,
		severity = raw.severity,
		source = raw.source,
		seq = raw.seq,
		uptime_ms = raw.uptime_ms,
	}
end

function M.compose(raw_facts, raw_events)
	raw_facts = table_or_empty(raw_facts)
	raw_events = table_or_empty(raw_events)
	return {
		software = M.normalise_software(raw_facts.software),
		updater = M.normalise_updater(raw_facts.updater),
		health = M.normalise_health(raw_facts.health),
		power = {
			battery = copy_named(raw_facts.power_battery, { 'pack_mV', 'per_cell_mV', 'ibat_mA', 'temp_mC', 'seq', 'uptime_ms' }),
			charger = copy(raw_facts.power_charger or {}),
			charger_config = copy(raw_facts.power_charger_config or {}),
		},
		environment = {
			temperature = copy(raw_facts.environment_temperature or {}),
			humidity = copy(raw_facts.environment_humidity or {}),
		},
		runtime = {
			memory = copy(raw_facts.runtime_memory or {}),
		},
		alerts = {
			charger = raw_events.charger_alert and M.normalise_charger_alert(raw_events.charger_alert) or nil,
		},
	}
end

return M
