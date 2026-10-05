-- services/net/domain/dns.lua
-- Product-level DNS policy intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'enabled', 'upstreams', 'search', 'zones', 'records', 'forwarders',
	'cache', 'security', 'domain', 'host_files', 'service_discovery', 'metadata', 'extensions',
}

-- Build a service record with a valid DNS-SD type, matching TCP/UDP protocol,
-- and a non-empty list of unique integer ports in 1..65535. Reject unknown fields.
local function normalise_service(_, value, path)
	local t, err = schema.require_plain_table(value, path)
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, { 'type', 'protocol', 'ports' }, path)
	if not ok then return nil, ferr end
	if type(t.type) ~= 'string' or not t.type:match('^_[%w%-]+%._[tu][cd]p$') then
		return nil, schema.err({ schema.path(path), 'type' }, 'must be a DNS-SD service type such as _ipp._tcp')
	end
	if t.protocol ~= 'tcp' and t.protocol ~= 'udp' then
		return nil, schema.err({ schema.path(path), 'protocol' }, 'must be tcp or udp')
	end
	if t.type:sub(-3) ~= t.protocol then
		return nil, schema.err({ schema.path(path), 'protocol' }, 'must match the service type transport')
	end
	local ports, perr = schema.require_plain_table(t.ports, { schema.path(path), 'ports' })
	if not ports then return nil, perr end
	local out, seen, count = {}, {}, 0
	for index, port in pairs(ports) do
		count = count + 1
		if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > #ports then
			return nil, schema.err({ schema.path(path), 'ports' }, 'must be a dense array of ports')
		end
		if type(port) ~= 'number' or port % 1 ~= 0 or port < 1 or port > 65535 then
			return nil, schema.err({ schema.path(path), 'ports', index }, 'must be an integer in 1..65535')
		end
		if seen[port] then return nil, schema.err({ schema.path(path), 'ports', index }, 'duplicate port') end
		seen[port], out[index] = true, port
	end
	if count == 0 or count ~= #ports then
		return nil, schema.err({ schema.path(path), 'ports' }, 'must be a non-empty dense array')
	end
	return { type = t.type, protocol = t.protocol, ports = out }
end

-- Build an IPv4 discovery policy with source/range IDs, at least one destination
-- and normalised services, defaulting enabled to true. Reject unknown fields;
-- checking that referenced segments and ranges exist happens in config validation.
local function normalise_discovery(_, value, path)
	local t, err = schema.require_plain_table(value, path)
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t,
		{ 'enabled', 'source_segment', 'advertise_to', 'address_range', 'family', 'services' }, path)
	if not ok then return nil, ferr end
	local enabled, eerr = schema.optional_boolean(t.enabled, { schema.path(path), 'enabled' })
	if eerr then return nil, eerr end
	local source, serr = schema.id(t.source_segment, { schema.path(path), 'source_segment' })
	if not source then return nil, serr end
	local range, rerr = schema.id(t.address_range, { schema.path(path), 'address_range' })
	if not range then return nil, rerr end
	local destinations, derr = schema.id_list(t.advertise_to, { schema.path(path), 'advertise_to' })
	if not destinations then return nil, derr end
	if #destinations == 0 then return nil, schema.err({ schema.path(path), 'advertise_to' }, 'must not be empty') end
	if t.family ~= 'ipv4' then return nil, schema.err({ schema.path(path), 'family' }, 'only ipv4 is supported') end
	local services, verr = schema.map(t.services, { schema.path(path), 'services' }, normalise_service)
	if not services then return nil, verr end
	if next(services) == nil then
		return nil, schema.err({ schema.path(path), 'services' }, 'must contain at least one service')
	end
	return {
		enabled = enabled ~= false, source_segment = source, advertise_to = destinations,
		address_range = range, family = t.family, services = services,
	}
end

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'dns' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'dns' })
	if not ok then return nil, ferr end
	local discovery, derr = schema.map(t.service_discovery, { 'net', 'dns', 'service_discovery' }, normalise_discovery)
	if not discovery then return nil, derr end
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
		service_discovery = discovery,
	}
	return schema.with_optional_extensions(out, t, { 'net', 'dns' })
end

return M
