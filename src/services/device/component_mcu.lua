-- services/device/component_mcu.lua
--
-- MCU-specific status normalisation.
--
-- This module accepts either:
--   * a plain/raw MCU status shape, or
--   * a more canonical structured MCU status shape
--
-- and returns one canonical public form used by the device projections.

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
		raw = {},
	}
end

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
