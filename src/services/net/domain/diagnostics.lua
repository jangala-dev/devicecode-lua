-- services/net/domain/diagnostics.lua
-- Product-level network diagnostics policy.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'probes', 'reflectors', 'schedules', 'limits', 'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'diagnostics' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'diagnostics' })
	if not ok then return nil, ferr end
	local out = {
		probes = schema.copy(t.probes or {}),
		reflectors = schema.copy(t.reflectors or {}),
		schedules = schema.copy(t.schedules or {}),
		limits = schema.copy(t.limits or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'diagnostics' })
end

return M
