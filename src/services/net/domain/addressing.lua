-- services/net/domain/addressing.lua
-- Global addressing, DHCP and DNS policy normalisation.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'ipv4', 'ipv6', 'dhcp', 'dns', 'pools', 'reservations', 'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'addressing' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'addressing' })
	if not ok then return nil, ferr end
	local out = {
		ipv4 = schema.copy(t.ipv4 or {}),
		ipv6 = schema.copy(t.ipv6 or {}),
		dhcp = schema.copy(t.dhcp or {}),
		dns = schema.copy(t.dns or {}),
		pools = schema.copy(t.pools or {}),
		reservations = schema.copy(t.reservations or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'addressing' })
end

return M
