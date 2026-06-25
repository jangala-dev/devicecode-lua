-- services/net/domain/shaping.lua
-- Product-level traffic shaping, fairness and QoS intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'enabled', 'profiles', 'classes', 'policies', 'links', 'segments',
	'clients', 'runtime', 'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'shaping' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'shaping' })
	if not ok then return nil, ferr end
	local out = {
		enabled = t.enabled == true,
		profiles = schema.copy(t.profiles or {}),
		classes = schema.copy(t.classes or {}),
		policies = schema.copy(t.policies or {}),
		links = schema.copy(t.links or {}),
		segments = schema.copy(t.segments or {}),
		clients = schema.copy(t.clients or {}),
		runtime = schema.copy(t.runtime or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'shaping' })
end

return M
