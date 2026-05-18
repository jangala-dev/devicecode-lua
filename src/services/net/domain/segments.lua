-- services/net/domain/segments.lua
-- Product-level network segment normalisation.  No HAL or backend knowledge.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'id', 'name', 'description', 'kind', 'enabled', 'protected', 'user_editable', 'purpose', 'vlan', 'addressing',
	'dhcp', 'dns', 'firewall', 'routing', 'shaping', 'vpn', 'policy',
	'tags', 'metadata', 'extensions',
}

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
		dhcp = schema.copy(t.dhcp or {}),
		dns = schema.copy(t.dns or {}),
		firewall = schema.copy(t.firewall or {}),
		routing = schema.copy(t.routing or {}),
		shaping = schema.copy(t.shaping or {}),
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
