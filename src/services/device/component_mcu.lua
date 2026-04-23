-- services/device/component_mcu.lua
--
-- MCU-specific fact composition.

local model = require 'services.device.model'

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
		incarnation = nil,
		software = {},
		updater = {},
		capabilities = {},
		source = {},
		health = nil,
		raw = {},
	}
end

local function normalize_software_fact(raw)
	raw = ensure_table(raw)
	return {
		version = raw.version or raw.fw_version or nil,
		build = raw.build or nil,
		image_id = raw.image_id or nil,
		boot_id = raw.boot_id or nil,
	}
end

local function normalize_updater_fact(raw)
	raw = ensure_table(raw)
	return {
		state = raw.state or raw.status or raw.kind or nil,
		last_error = raw.last_error or raw.err or nil,
		pending_version = raw.pending_version or nil,
	}
end

local function normalize_health_fact(raw)
	raw = ensure_table(raw)
	if raw.state ~= nil then
		return raw.state
	end
	if raw.health ~= nil then
		return raw.health
	end
	if next(raw) ~= nil then
		return 'ok'
	end
	return nil
end

function M.compose(raw_facts, _fact_state)
	raw_facts = type(raw_facts) == 'table' and raw_facts or {}

	local software_raw = raw_facts.software
	local updater_raw = raw_facts.updater
	local health_raw = raw_facts.health

	local any_seen = software_raw ~= nil or updater_raw ~= nil or health_raw ~= nil
	local software = normalize_software_fact(software_raw)
	local updater = normalize_updater_fact(updater_raw)
	local health = normalize_health_fact(health_raw)
	local incarnation = software.boot_id
		or (type(updater_raw) == 'table' and updater_raw.boot_id)
		or (type(health_raw) == 'table' and health_raw.boot_id)
		or nil

	return {
		available = any_seen,
		ready = software_raw ~= nil and updater_raw ~= nil,
		incarnation = incarnation,
		software = software,
		updater = updater,
		health = health,
		capabilities = {},
		source = {
			kind = 'member',
		},
		raw = {
			software = copy(software_raw),
			updater = copy(updater_raw),
			health = copy(health_raw),
		},
	}
end

return M
