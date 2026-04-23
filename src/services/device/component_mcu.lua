-- services/device/component_mcu.lua
--
-- MCU-specific status normalisation and composition.
--
-- The long-term shape for MCU observation is split retained facts at the member
-- boundary, composed into one stable local component view by the CM5 device
-- service.
--
-- This module therefore supports two modes:
--   * legacy compatibility: normalize one pre-composed raw status payload
--   * preferred path: compose canonical MCU state from split facts

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

-- Legacy compatibility path -------------------------------------------------

function M.normalize_plain_status(raw)
	raw = type(raw) == 'table' and raw or {}

	local out = M.empty()
	out.available = next(raw) ~= nil
	out.ready = raw.ready ~= false
	out.incarnation = raw.incarnation or raw.boot_id or nil

	out.software = {
		version = raw.version or raw.fw_version or nil,
		build = raw.build or nil,
		image_id = raw.image_id or nil,
		boot_id = raw.boot_id or nil,
	}

	out.updater = {
		state = raw.updater_state or raw.state or raw.status or raw.kind or nil,
		last_error = raw.last_error or raw.err or nil,
	}

	out.source = copy(raw.source)
	out.raw = copy(raw)
	return out
end

function M.normalize_canonical_status(raw)
	raw = ensure_table(raw)

	local out = M.empty()
	out.available = raw.available ~= false
	out.ready = raw.ready ~= false
	out.incarnation = raw.incarnation

	out.software = ensure_table(copy(raw.software))
	out.updater = ensure_table(copy(raw.updater))
	out.capabilities = ensure_table(copy(raw.capabilities))
	out.source = ensure_table(copy(raw.source))
	out.health = raw.health
	out.raw = copy(raw.raw or raw)

	return out
end

function M.normalize_status(raw)
	if type(raw) == 'table' and (
		type(raw.software) == 'table' or
		type(raw.updater) == 'table' or
		raw.incarnation ~= nil
	) then
		return M.normalize_canonical_status(raw)
	end

	return M.normalize_plain_status(raw)
end

function M.mark_unavailable(reason)
	local out = M.empty()
	out.updater = {
		state = 'unavailable',
		last_error = reason,
	}
	out.raw = {
		state = 'unavailable',
		err = reason,
	}
	return out
end

return M
