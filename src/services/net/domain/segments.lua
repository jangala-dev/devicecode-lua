-- services/net/domain/segments.lua
-- Product-level network segment normalisation.  No HAL or backend knowledge.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'id', 'name', 'description', 'kind', 'enabled', 'protected', 'user_editable', 'purpose', 'vlan', 'addressing',
	'dhcp', 'dns', 'firewall', 'routing', 'shaping', 'vpn', 'policy', 'l2',
	'tags', 'metadata', 'extensions',
}


local SHAPING_ALLOWED = {
	'enabled', 'download', 'upload', 'host_default', 'host_overrides',
	'fq_codel', 'metadata', 'extensions',
}

local DIRECTION_ALLOWED = { 'enabled', 'limit', 'metadata', 'extensions' }
local HOST_ALLOWED = {
	'mode', 'all_hosts', 'download', 'upload', 'fq_codel', 'metadata', 'extensions',
}
local HOST_DIRECTION_ALLOWED = { 'enabled', 'sustained_rate', 'peak_rate', 'burst_budget', 'metadata', 'extensions' }

local function normalise_direction(t, path, require_limit)
	if t == nil then return nil, nil end
	local v, err = schema.require_plain_table(t, path)
	if not v then return nil, err end
	local ok, ferr = schema.check_allowed_fields(v, DIRECTION_ALLOWED, path)
	if not ok then return nil, ferr end
	if require_limit and (type(v.limit) ~= 'string' or v.limit == '') then
		return nil, schema.err({ schema.path(path), 'limit' }, 'must be a non-empty rate string')
	end
	return schema.with_optional_extensions({ enabled = v.enabled ~= false, limit = v.limit }, v, path)
end

local function normalise_host_direction(t, path, required)
	if t == nil then
		if required then return nil, schema.err(path, 'is required') end
		return nil, nil
	end
	local v, err = schema.require_plain_table(t, path)
	if not v then return nil, err end
	local ok, ferr = schema.check_allowed_fields(v, HOST_DIRECTION_ALLOWED, path)
	if not ok then return nil, ferr end
	for _, field in ipairs({ 'sustained_rate', 'peak_rate', 'burst_budget' }) do
		if type(v[field]) ~= 'string' or v[field] == '' then
			return nil, schema.err({ schema.path(path), field }, 'must be a non-empty rate string')
		end
	end
	return schema.with_optional_extensions({
		enabled = v.enabled ~= false,
		sustained_rate = v.sustained_rate,
		peak_rate = v.peak_rate,
		burst_budget = v.burst_budget,
	}, v, path)
end

local function normalise_host_default(t, path)
	if t == nil then return nil, nil end
	local v, err = schema.require_plain_table(t, path)
	if not v then return nil, err end
	local ok, ferr = schema.check_allowed_fields(v, HOST_ALLOWED, path)
	if not ok then return nil, ferr end
	if v.mode ~= 'budgeted_peak' then
		return nil, schema.err({ schema.path(path), 'mode' }, 'must be budgeted_peak')
	end
	local download, derr = normalise_host_direction(v.download, { schema.path(path), 'download' }, true)
	if not download then return nil, derr end
	local upload, uerr = normalise_host_direction(v.upload, { schema.path(path), 'upload' }, true)
	if not upload then return nil, uerr end
	local out = {
		mode = v.mode,
		all_hosts = v.all_hosts ~= false,
		download = download,
		upload = upload,
		fq_codel = schema.copy(v.fq_codel or {}),
	}
	return schema.with_optional_extensions(out, v, path)
end

local function normalise_shaping(v, path)
	if v == nil then return {}, nil end
	local t, err = schema.require_plain_table(v, path)
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, SHAPING_ALLOWED, path)
	if not ok then return nil, ferr end
	local download, derr = normalise_direction(t.download, { schema.path(path), 'download' }, false)
	if derr then return nil, derr end
	local upload, uerr = normalise_direction(t.upload, { schema.path(path), 'upload' }, false)
	if uerr then return nil, uerr end
	local host_default, herr = normalise_host_default(t.host_default, { schema.path(path), 'host_default' })
	if herr then return nil, herr end
	local out = {
		enabled = t.enabled ~= false,
		download = download,
		upload = upload,
		host_default = host_default,
		host_overrides = schema.copy(t.host_overrides or {}),
		fq_codel = schema.copy(t.fq_codel or {}),
	}
	return schema.with_optional_extensions(out, t, path)
end

local function normalise_vlan(v, path)
	if v == nil then return nil, nil end
	if type(v) == 'number' then
		if v % 1 ~= 0 or v < 1 or v > 4094 then return nil, schema.err(path, 'must be a VLAN id in the range 1..4094') end
		return { id = v }, nil
	end
	local t, err = schema.require_plain_table(v, path)
	if not t then return nil, err end
	local out = schema.copy(t)
	if out.reserved ~= nil then
		if type(out.reserved) ~= 'string' or out.reserved == '' then
			return nil, schema.err({ schema.path(path), 'reserved' }, 'must be a non-empty reserved VLAN name')
		end
	end
	if out.auto ~= nil then
		if type(out.auto) ~= 'string' or out.auto == '' then
			return nil, schema.err({ schema.path(path), 'auto' }, 'must be a non-empty VLAN range name')
		end
	end
	if out.id ~= nil then
		local id, ierr = schema.optional_integer(out.id, { schema.path(path), 'id' })
		if ierr then return nil, ierr end
		if id < 1 or id > 4094 then return nil, schema.err({ schema.path(path), 'id' }, 'must be in the range 1..4094') end
		out.id = id
	end
	return out, nil
end

function M.normalise_record(id, rec, path)
	local t, err = schema.require_plain_table(rec, path)
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, path)
	if not ok then return nil, ferr end
	if t.id ~= nil and t.id ~= id then return nil, schema.err({ schema.path(path), 'id' }, 'must match the map key') end

	local vlan, verr = normalise_vlan(t.vlan, { schema.path(path), 'vlan' })
	if verr then return nil, verr end
	local tags, terr = schema.id_list(t.tags, { schema.path(path), 'tags' })
	if terr then return nil, terr end

	local shaping, sherr = normalise_shaping(t.shaping, { schema.path(path), 'shaping' })
	if not shaping then return nil, sherr end

	local out = {
		id = id,
		name = t.name or id,
		description = t.description,
		kind = t.kind or 'lan',
		enabled = t.enabled ~= false,
		protected = t.protected == true,
		user_editable = t.user_editable ~= false,
		purpose = t.purpose,
		vlan = vlan,
		addressing = schema.copy(t.addressing or {}),
		l2 = schema.copy(t.l2 or {}),
		dhcp = schema.copy(t.dhcp or {}),
		dns = schema.copy(t.dns or {}),
		firewall = schema.copy(t.firewall or {}),
		routing = schema.copy(t.routing or {}),
		shaping = shaping,
		vpn = schema.copy(t.vpn or {}),
		policy = schema.copy(t.policy or {}),
		tags = tags,
	}
	return schema.with_optional_extensions(out, t, path)
end

function M.normalise(input)
	return schema.map(input, { 'net', 'segments' }, M.normalise_record)
end

return M
