-- services/net/domain/dns.lua
-- Product-level DNS policy intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'enabled', 'upstreams', 'search', 'zones', 'records', 'forwarders',
	'cache', 'security', 'domain', 'host_files', 'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'dns' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'dns' })
	if not ok then return nil, ferr end
	local out = {
		enabled = t.enabled ~= false,
		upstreams = schema.copy(t.upstreams or {}),
		search = schema.copy(t.search or {}),
		zones = schema.copy(t.zones or {}),
		records = schema.copy(t.records or {}),
		forwarders = schema.copy(t.forwarders or {}),
		cache = schema.copy(t.cache or {}),
		security = schema.copy(t.security or {}),
		domain = t.domain,
		host_files = schema.copy(t.host_files or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'dns' })
end

return M
