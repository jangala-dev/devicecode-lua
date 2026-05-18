-- services/net/domain/multiwan.lua
-- Product-level WAN and multi-WAN policy intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'enabled', 'policy', 'members', 'health', 'runtime', 'failover',
	'load_balancing', 'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'wan' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'wan' })
	if not ok then return nil, ferr end
	local out = {
		enabled = t.enabled ~= false,
		policy = t.policy or 'failover',
		members = schema.copy(t.members or {}),
		health = schema.copy(t.health or {}),
		runtime = schema.copy(t.runtime or {}),
		failover = schema.copy(t.failover or {}),
		load_balancing = schema.copy(t.load_balancing or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'wan' })
end

return M
