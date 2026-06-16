-- services/wired/config.lua
-- Strict cfg/wired normalisation boundary.
--
-- Wired owns appliance-level wired surfaces and their attachment to net
-- segments.  It does not own segment identity, VLAN allocation, routing,
-- firewall or switch-driver implementation.

local tablex = require 'shared.table'

local M = {}

M.SCHEMA = 'devicecode.config/wired/1'
M.INTENT_SCHEMA = 'devicecode.wired.intent/1'
M.DEFAULT_VERSION = 1

local ID_PATTERN = '^[%w][%w%._%-]*$'

local function copy(v) return tablex.deep_copy(v) end
local function is_plain_table(v) return type(v) == 'table' and getmetatable(v) == nil end

local function path(p)
	if type(p) == 'table' then
		local out = {}
		for i = 1, #p do out[i] = tostring(p[i]) end
		return table.concat(out, '.')
	end
	return tostring(p or 'value')
end

local function err(p, msg)
	return ('%s: %s'):format(path(p), tostring(msg))
end

local function id(v, p)
	if type(v) ~= 'string' or v == '' then return nil, err(p, 'must be a non-empty string') end
	if not v:match(ID_PATTERN) then
		return nil, err(p, 'must contain only letters, digits, underscore, hyphen or dot, and must start with a word character')
	end
	return v, nil
end

local function string_list(v, p)
	if v == nil then return {}, nil end
	if type(v) ~= 'table' or not tablex.is_array(v) then return nil, err(p, 'must be an array of strings') end
	local out, seen = {}, {}
	for i = 1, #v do
		local item, ierr = id(v[i], { path(p), i })
		if not item then return nil, ierr end
		if not seen[item] then
			seen[item] = true
			out[#out + 1] = item
		end
	end
	return out, nil
end

local function optional_string(v, p)
	if v == nil then return nil, nil end
	if type(v) ~= 'string' then return nil, err(p, 'must be a string') end
	return v, nil
end

local function check_allowed(t, allowed, p)
	if not is_plain_table(t) then return nil, err(p, 'must be a plain table') end
	local ok = {}
	for i = 1, #allowed do ok[allowed[i]] = true end
	for k in pairs(t) do
		if not ok[k] then return nil, err({ path(p), k }, 'field is not part of devicecode.config/wired/1') end
	end
	return true, nil
end

local ATTACHMENT_FIELDS = {
	'mode', 'segment', 'segments', 'required_segments', 'user_segments', 'native_segment',
	'tagged', 'untagged', 'metadata', 'extensions',
}

local function normalise_attachment(v, p)
	if not is_plain_table(v) then return nil, err(p, 'attachment must be a table') end
	local ok, ferr = check_allowed(v, ATTACHMENT_FIELDS, p)
	if not ok then return nil, ferr end
	local mode = v.mode or ((v.segment ~= nil) and 'access' or 'trunk')
	if mode ~= 'access' and mode ~= 'trunk' and mode ~= 'none' then
		return nil, err({ path(p), 'mode' }, 'must be access, trunk or none')
	end
	local segment = nil
	if v.segment ~= nil then
		local serr
		segment, serr = id(v.segment, { path(p), 'segment' })
		if not segment then return nil, serr end
	end
	local segments, sgerr = string_list(v.segments, { path(p), 'segments' })
	if not segments then return nil, sgerr end
	local required, rerr = string_list(v.required_segments, { path(p), 'required_segments' })
	if not required then return nil, rerr end
	local native = nil
	if v.native_segment ~= nil then
		local nerr
		native, nerr = id(v.native_segment, { path(p), 'native_segment' })
		if not native then return nil, nerr end
	end
	if mode == 'access' and not segment then
		return nil, err({ path(p), 'segment' }, 'is required for access attachments')
	end
	if mode == 'trunk' and segment ~= nil then
		return nil, err({ path(p), 'segment' }, 'must not be used for trunk attachments')
	end
	if v.user_segments ~= nil and v.user_segments ~= 'all-realised-user-segments' and type(v.user_segments) ~= 'table' then
		return nil, err({ path(p), 'user_segments' }, 'must be all-realised-user-segments or an array of segment ids')
	end
	local user_segments = v.user_segments
	if type(user_segments) == 'table' then
		local uerr
		user_segments, uerr = string_list(user_segments, { path(p), 'user_segments' })
		if not user_segments then return nil, uerr end
	end
	return {
		mode = mode,
		segment = segment,
		segments = segments,
		required_segments = required,
		user_segments = user_segments,
		native_segment = native,
		tagged = copy(v.tagged),
		untagged = copy(v.untagged),
		metadata = copy(v.metadata),
		extensions = copy(v.extensions),
	}, nil
end

local SURFACE_FIELDS = {
	'id', 'name', 'label', 'description', 'kind', 'role', 'enabled', 'protected',
	'attachment', 'capabilities', 'tags', 'metadata', 'extensions',
}

local function normalise_surface(surface_id, rec, p)
	if not is_plain_table(rec) then return nil, err(p, 'surface must be a table') end
	local ok, ferr = check_allowed(rec, SURFACE_FIELDS, p)
	if not ok then return nil, ferr end
	if rec.id ~= nil and rec.id ~= surface_id then return nil, err({ path(p), 'id' }, 'must match the map key') end
	local attachment, aerr = normalise_attachment(rec.attachment or { mode = 'none' }, { path(p), 'attachment' })
	if not attachment then return nil, aerr end
	local protected = rec.protected == true
	local enabled = rec.enabled ~= false
	if protected then
		if not enabled then
			return nil, err({ path(p), 'enabled' }, 'protected surfaces cannot be disabled')
		end
		if attachment.mode ~= 'trunk' then
			return nil, err({ path(p), 'attachment', 'mode' }, 'protected surfaces must be trunk attachments')
		end
		if #(attachment.required_segments or {}) == 0 then
			return nil, err({ path(p), 'attachment', 'required_segments' }, 'protected trunks must declare required system segments')
		end
	end
	local tags, terr = string_list(rec.tags, { path(p), 'tags' })
	if not tags then return nil, terr end
	local name, nerr = optional_string(rec.name or rec.label, { path(p), 'name' })
	if nerr then return nil, nerr end
	return {
		id = surface_id,
		surface_id = surface_id,
		name = name or surface_id,
		label = rec.label or name or surface_id,
		description = rec.description,
		kind = rec.kind or 'ethernet-port',
		role = rec.role or 'access',
		enabled = enabled,
		protected = protected,
		attachment = attachment,
		capabilities = copy(rec.capabilities or {}),
		tags = tags,
		metadata = copy(rec.metadata),
		extensions = copy(rec.extensions),
	}, nil
end

local function normalise_surfaces(v)
	if v == nil then return {}, nil end
	if not is_plain_table(v) or tablex.is_array(v) then return nil, err({ 'wired', 'surfaces' }, 'must be a map keyed by surface id') end
	local out = {}
	local keys = tablex.sorted_keys(v)
	for i = 1, #keys do
		local surface_id, ierr = id(tostring(keys[i]), { 'wired', 'surfaces', keys[i] })
		if not surface_id then return nil, ierr end
		local rec, rerr = normalise_surface(surface_id, v[keys[i]], { 'wired', 'surfaces', surface_id })
		if not rec then return nil, rerr end
		out[surface_id] = rec
	end
	return out, nil
end

local TOP_LEVEL = { 'schema', 'version', 'product', 'description', 'surfaces', 'policies', 'runtime', 'metadata', 'extensions' }

function M.normalise(raw, opts)
	opts = opts or {}
	if raw ~= nil and raw.data ~= nil then raw = raw.data end
	if raw == nil then raw = { schema = M.SCHEMA, version = M.DEFAULT_VERSION, surfaces = {} } end
	if not is_plain_table(raw) then return nil, 'cfg/wired must be a table' end
	if raw.schema ~= M.SCHEMA then return nil, ('cfg/wired schema must be %s'):format(M.SCHEMA) end
	local ok, ferr = check_allowed(raw, TOP_LEVEL, { 'cfg', 'wired' })
	if not ok then return nil, ferr end
	local version = raw.version or M.DEFAULT_VERSION
	if type(version) ~= 'number' or version % 1 ~= 0 or version < 1 then return nil, 'cfg/wired.version must be a positive integer' end
	local surfaces, serr = normalise_surfaces(raw.surfaces)
	if not surfaces then return nil, serr end
	return {
		schema = M.INTENT_SCHEMA,
		config_schema = M.SCHEMA,
		version = version,
		rev = opts.rev or raw.rev or 0,
		generation = opts.generation or 0,
		product = raw.product,
		description = raw.description,
		surfaces = surfaces,
		policies = copy(raw.policies or {}),
		runtime = copy(raw.runtime or {}),
		metadata = copy(raw.metadata),
		extensions = copy(raw.extensions),
	}, nil
end

M._test = {
	normalise_attachment = normalise_attachment,
}

return M
