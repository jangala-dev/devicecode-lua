-- services/device/component_host.lua
-- Pure host component normalisation, action description, and availability overlay.

local model = require 'services.device.model'
local tablex = require 'shared.table'

local M = { kind = 'host' }

local table_or_empty = tablex.table_or_empty

local function copy(v)
	return model.copy_value(v)
end

local first_non_nil = tablex.first_non_nil

function M.normalise_software(raw)
	raw = table_or_empty(raw)
	return {
		version = raw.version or raw.fw_version,
		build = raw.build or raw.build_id,
		image_id = raw.image_id,
		boot_id = raw.boot_id,
		bootedfw = raw.bootedfw,
		targetfw = raw.targetfw,
		upgrade_available = raw.upgrade_available,
		hw_revision = raw.hw_revision,
		serial = raw.serial,
		board_revision = raw.board_revision,
	}
end

function M.normalise_updater(raw)
	raw = table_or_empty(raw)
	return {
		state = raw.state or raw.raw_state or raw.status or raw.kind,
		raw_state = raw.raw_state,
		staged = raw.staged,
		artifact_ref = raw.artifact_ref,
		artifact_meta = copy(raw.artifact_meta),
		expected_image_id = raw.expected_image_id,
		last_error = raw.last_error or raw.err,
	}
end

function M.normalise_health(raw)
	if type(raw) ~= 'table' then return raw end
	return {
		health = first_non_nil(raw.health, raw.state, raw.status, raw.kind),
		fault = first_non_nil(raw.fault, raw.fault_code, raw.error, raw.err),
		details = copy(raw.details),
	}
end

function M.normalise_fact(fact, raw)
	if fact == 'software' then return M.normalise_software(raw), nil end
	if fact == 'updater' then return M.normalise_updater(raw), nil end
	if fact == 'health' then return M.normalise_health(raw), nil end
	return copy(raw), nil
end
function M.normalise_event(_, raw)
	return copy(raw), nil
end
function M.compose(raw_facts)
	raw_facts = table_or_empty(raw_facts)
	return {
		software = M.normalise_software(raw_facts.software),
		updater = M.normalise_updater(raw_facts.updater),
		health = M.normalise_health(raw_facts.health),
		power = copy(raw_facts.power or {}),
		environment = copy(raw_facts.environment or {}),
		runtime = copy(raw_facts.runtime or {}),
		alerts = copy(raw_facts.alerts or {}),
	}
end

function M.action_spec(_, _, _, base_spec)
	return copy(base_spec), nil
end

function M.availability(base, rec)
	local out = copy(base)
	local facts = table_or_empty(rec and rec.raw_facts)
	local sw_seen = rec and rec.fact_state and rec.fact_state.software and rec.fact_state.software.seen == true
	local health = facts.health

	-- Host software is useful but should not make a visible host wholly absent
	-- where other host sources are alive.  This keeps status reads informative
	-- during updater bring-up or partial raw-source availability.
	if out.reason == 'missing_required_fact' and out.details and out.details.missing_fact == 'software' then
		out.availability = 'degraded'
		out.health = 'warning'
		out.reason = 'missing_host_software'
	end

	if type(health) == 'table' and health.fault ~= nil and health.fault ~= false then
		out.availability = 'unavailable'
		out.health = 'fault'
		out.reason = 'host_fault'
	elseif type(health) == 'string' and (health == 'fault' or health == 'failed' or health == 'error') then
		out.availability = 'unavailable'
		out.health = 'fault'
		out.reason = 'host_fault'
	elseif sw_seen and out.availability == 'unknown' then
		out.availability = 'degraded'
		out.health = out.health or 'warning'
		out.reason = out.reason or 'partial_host_state'
	end

	return out
end

return M
