-- services/net/domain/routing.lua
-- Product-level routing and policy-routing intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'tables', 'routes', 'rules', 'defaults', 'metadata', 'extensions',
}

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'routing' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'routing' })
	if not ok then return nil, ferr end
	local out = {
		tables = schema.copy(t.tables or {}),
		routes = schema.copy(t.routes or {}),
		rules = schema.copy(t.rules or {}),
		defaults = schema.copy(t.defaults or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'routing' })
end

return M
