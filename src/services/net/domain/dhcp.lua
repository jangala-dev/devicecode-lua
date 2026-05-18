-- services/net/domain/dhcp.lua
-- Product-level DHCP policy intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'enabled', 'defaults', 'reservations', 'options', 'relays', 'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'dhcp' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'dhcp' })
	if not ok then return nil, ferr end
	local out = {
		enabled = t.enabled ~= false,
		defaults = schema.copy(t.defaults or {}),
		reservations = schema.copy(t.reservations or {}),
		options = schema.copy(t.options or {}),
		relays = schema.copy(t.relays or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'dhcp' })
end

return M
