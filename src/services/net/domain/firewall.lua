-- services/net/domain/firewall.lua
-- Product-level firewall and isolation policy normalisation.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'defaults', 'zones', 'policies', 'rules', 'nat', 'port_forwards',
	'isolation', 'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'firewall' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'firewall' })
	if not ok then return nil, ferr end
	local out = {
		defaults = schema.copy(t.defaults or {}),
		zones = schema.copy(t.zones or {}),
		policies = schema.copy(t.policies or {}),
		rules = schema.copy(t.rules or {}),
		nat = schema.copy(t.nat or {}),
		port_forwards = schema.copy(t.port_forwards or {}),
		isolation = schema.copy(t.isolation or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'firewall' })
end

return M
