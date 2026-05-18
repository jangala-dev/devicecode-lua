-- services/net/domain/interfaces.lua
-- Product-level logical interface normalisation.  No OS interface names are required.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'id', 'name', 'description', 'kind', 'role', 'enabled', 'segment',
	'segments', 'endpoint', 'parent', 'members', 'mtu', 'mac', 'addressing',
	'policy', 'tags', 'metadata', 'extensions',
}

function M.normalise_record(id, rec, path)
	local t, err = schema.require_plain_table(rec, path)
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, path)
	if not ok then return nil, ferr end
	if t.id ~= nil and t.id ~= id then return nil, schema.err({ schema.path(path), 'id' }, 'must match the map key') end

	local segment = nil
	if t.segment ~= nil then
		segment, err = schema.id(t.segment, { schema.path(path), 'segment' })
		if err then return nil, err end
	end
	local segments, serr = schema.id_list(t.segments, { schema.path(path), 'segments' })
	if serr then return nil, serr end
	local members, merr = schema.id_list(t.members, { schema.path(path), 'members' })
	if merr then return nil, merr end
	local tags, terr = schema.id_list(t.tags, { schema.path(path), 'tags' })
	if terr then return nil, terr end
	local mtu, mtu_err = schema.optional_integer(t.mtu, { schema.path(path), 'mtu' })
	if mtu_err then return nil, mtu_err end

	local out = {
		id = id,
		name = t.name or id,
		description = t.description,
		kind = t.kind or 'logical',
		role = t.role,
		enabled = t.enabled ~= false,
		segment = segment,
		segments = segments,
		endpoint = schema.copy(t.endpoint or {}),
		parent = t.parent,
		members = members,
		mtu = mtu,
		mac = t.mac,
		addressing = schema.copy(t.addressing or {}),
		policy = schema.copy(t.policy or {}),
		tags = tags,
	}
	return schema.with_optional_extensions(out, t, path)
end

function M.normalise(input)
	return schema.map(input, { 'net', 'interfaces' }, M.normalise_record)
end

return M
