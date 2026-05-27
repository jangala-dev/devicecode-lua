-- services/net/domain/routing.lua
-- Product-level routing and policy-routing intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'tables', 'routes', 'rules', 'defaults', 'metadata', 'extensions',
}

local ROUTE_ALLOWED = {
	'kind', 'target', 'netmask', 'interface', 'gateway', 'metric', 'table',
	'description', 'metadata', 'extensions',
}

local function is_ipv4_addr(s)
	if type(s) ~= 'string' then return false end
	local a, b, c, d = s:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	if not a then return false end
	for _, part in ipairs({ a, b, c, d }) do
		local n = tonumber(part)
		if n == nil or n < 0 or n > 255 then return false end
	end
	return true
end

local function normalise_route(id, v, path)
	local t, err = schema.require_plain_table(v, path)
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ROUTE_ALLOWED, path)
	if not ok then return nil, ferr end
	local kind = t.kind
	if kind ~= 'host' and kind ~= 'subnet' then
		return nil, schema.err({ schema.path(path), 'kind' }, "must be 'host' or 'subnet'")
	end
	local target, terr = schema.optional_string(t.target, { schema.path(path), 'target' })
	if terr then return nil, terr end
	if target == nil or target == '' then return nil, schema.err({ schema.path(path), 'target' }, 'must be a non-empty string') end
	local iface, ierr = schema.optional_string(t.interface, { schema.path(path), 'interface' })
	if ierr then return nil, ierr end
	if iface == nil or iface == '' then return nil, schema.err({ schema.path(path), 'interface' }, 'must be a non-empty string') end
	local netmask, nerr = schema.optional_string(t.netmask, { schema.path(path), 'netmask' })
	if nerr then return nil, nerr end
	if kind == 'host' then
		if not is_ipv4_addr(target) then return nil, schema.err({ schema.path(path), 'target' }, 'host route target must be a single IPv4 address') end
		netmask = '255.255.255.255'
	elseif kind == 'subnet' then
		if netmask == nil or netmask == '' then return nil, schema.err({ schema.path(path), 'netmask' }, 'subnet route requires netmask') end
	end
	local gateway, gerr = schema.optional_string(t.gateway, { schema.path(path), 'gateway' })
	if gerr then return nil, gerr end
	local metric, merr = schema.optional_integer(t.metric, { schema.path(path), 'metric' })
	if merr then return nil, merr end
	local table_name, taberr = schema.optional_string(t.table, { schema.path(path), 'table' })
	if taberr then return nil, taberr end
	local desc, derr = schema.optional_string(t.description, { schema.path(path), 'description' })
	if derr then return nil, derr end
	local out = {
		kind = kind,
		target = target,
		netmask = netmask,
		interface = iface,
		gateway = gateway,
		metric = metric,
		table = table_name,
		description = desc,
	}
	return schema.with_optional_extensions(out, t, path)
end

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'routing' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'routing' })
	if not ok then return nil, ferr end
	local routes, rerr = schema.map(t.routes, { 'net', 'routing', 'routes' }, normalise_route)
	if not routes then return nil, rerr end
	local out = {
		tables = schema.copy(t.tables or {}),
		routes = routes,
		rules = schema.copy(t.rules or {}),
		defaults = schema.copy(t.defaults or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'routing' })
end

return M
