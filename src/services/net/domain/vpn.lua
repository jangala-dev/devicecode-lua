-- services/net/domain/vpn.lua
-- Product-level VPN and overlay transport intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'enabled', 'tunnels', 'peers', 'policies', 'routes', 'overlays',
	'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'vpn' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'vpn' })
	if not ok then return nil, ferr end
	local out = {
		enabled = t.enabled == true,
		tunnels = schema.copy(t.tunnels or {}),
		peers = schema.copy(t.peers or {}),
		policies = schema.copy(t.policies or {}),
		routes = schema.copy(t.routes or {}),
		overlays = schema.copy(t.overlays or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'vpn' })
end

return M
