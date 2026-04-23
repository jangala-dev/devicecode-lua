-- services/device/component_host.lua
--
-- Host/CM5-specific fact composition.
--
-- The long-term shape for host observation mirrors the MCU path:
-- split retained facts at the provider boundary, composed into one stable
-- local component view by the device service.

local model = require 'services.device.model'

local M = {}

local function copy(v)
	return model.copy_value(v)
end

local function ensure_table(v)
	return type(v) == 'table' and v or {}
end

local function normalize_software_fact(raw)
	raw = ensure_table(raw)
	return {
		version = raw.version or raw.fw_version or nil,
		build = raw.build or nil,
		image_id = raw.image_id or nil,
		boot_id = raw.boot_id or nil,
		bootedfw = raw.bootedfw or nil,
		targetfw = raw.targetfw or nil,
		upgrade_available = raw.upgrade_available or nil,
		hw_revision = raw.hw_revision or nil,
		serial = raw.serial or nil,
		board_revision = raw.board_revision or nil,
	}
end

local function normalize_updater_fact(raw)
	raw = ensure_table(raw)
	return {
		state = raw.state or raw.raw_state or raw.status or raw.kind or nil,
		raw_state = raw.raw_state or nil,
		staged = raw.staged,
		artifact_ref = raw.artifact_ref,
		artifact_meta = raw.artifact_meta,
		expected_version = raw.expected_version,
		last_error = raw.last_error or raw.err or nil,
		updated_at = raw.updated_at,
	}
end

local function normalize_health_fact(raw)
	raw = ensure_table(raw)
	if raw.state ~= nil then return raw.state end
	if raw.health ~= nil then return raw.health end
	if next(raw) ~= nil then return 'ok' end
	return nil
end

function M.compose(raw_facts, fact_state)
	raw_facts = type(raw_facts) == 'table' and raw_facts or {}
	fact_state = type(fact_state) == 'table' and fact_state or {}

	local software_raw = raw_facts.software
	local updater_raw = raw_facts.updater
	local health_raw = raw_facts.health

	local any_seen = false
	for _, meta in pairs(fact_state) do
		if type(meta) == 'table' and meta.seen == true then
			any_seen = true
			break
		end
	end
	if not any_seen then
		any_seen = software_raw ~= nil or updater_raw ~= nil or health_raw ~= nil
	end

	local software = normalize_software_fact(software_raw)
	local updater = normalize_updater_fact(updater_raw)
	local health = normalize_health_fact(health_raw)

	local software_seen = type(fact_state.software) == 'table' and fact_state.software.seen == true or software_raw ~= nil
	local updater_seen = type(fact_state.updater) == 'table' and fact_state.updater.seen == true or updater_raw ~= nil

	return {
		available = any_seen,
		ready = software_seen and updater_seen,
		software = software,
		updater = updater,
		health = health,
		capabilities = {},
		source = {
			kind = 'host',
		},
		raw = {
			software = copy(software_raw),
			updater = copy(updater_raw),
			health = copy(health_raw),
		},
	}
end

return M
