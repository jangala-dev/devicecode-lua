-- services/net/schema.lua
-- Strict product-level cfg/net schema helpers.
--
-- This module is pure.  It defines the NET configuration contract and small
-- normalisation helpers used by the domain modules.  Compatibility with older
-- shapes must not be added here; migration belongs outside the NET service.

local tablex = require 'shared.table'

local M = {}

M.CONFIG_SCHEMA = 'devicecode.config/net/1'
M.INTENT_SCHEMA = 'devicecode.net.intent/1'
M.DEFAULT_VERSION = 1

local ID_PATTERN = '^[%w][%w%._%-]*$'

function M.copy(v)
	return tablex.deep_copy(v)
end

function M.is_plain_table(v)
	return type(v) == 'table' and getmetatable(v) == nil
end

function M.path(path)
	if type(path) == 'table' then
		local out = {}
		for i = 1, #path do out[i] = tostring(path[i]) end
		return table.concat(out, '.')
	end
	return tostring(path or 'value')
end

function M.err(path, message)
	return ('%s: %s'):format(M.path(path), tostring(message))
end

function M.require_plain_table(v, path)
	if not M.is_plain_table(v) then
		return nil, M.err(path, 'must be a plain table')
	end
	return v, nil
end

function M.optional_plain_table(v, path)
	if v == nil then return {}, nil end
	return M.require_plain_table(v, path)
end

function M.id(v, path)
	if type(v) ~= 'string' or v == '' then
		return nil, M.err(path, 'must be a non-empty string')
	end
	if not v:match(ID_PATTERN) then
		return nil, M.err(path, 'must contain only letters, digits, underscore, hyphen or dot, and must start with a word character')
	end
	return v, nil
end

function M.optional_string(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'string' then return nil, M.err(path, 'must be a string') end
	return v, nil
end

function M.optional_boolean(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'boolean' then return nil, M.err(path, 'must be a boolean') end
	return v, nil
end

function M.optional_number(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'number' then return nil, M.err(path, 'must be a number') end
	return v, nil
end

function M.optional_integer(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'number' or v % 1 ~= 0 then return nil, M.err(path, 'must be an integer') end
	return v, nil
end

function M.string_list(v, path)
	if v == nil then return {}, nil end
	if type(v) ~= 'table' or not tablex.is_array(v) then
		return nil, M.err(path, 'must be an array of strings')
	end
	local out = {}
	for i = 1, #v do
		if type(v[i]) ~= 'string' or v[i] == '' then
			return nil, M.err({ M.path(path), i }, 'must be a non-empty string')
		end
		out[i] = v[i]
	end
	return out, nil
end

function M.id_list(v, path)
	local list, err = M.string_list(v, path)
	if not list then return nil, err end
	for i = 1, #list do
		local _, ierr = M.id(list[i], { M.path(path), i })
		if ierr then return nil, ierr end
	end
	return list, nil
end

function M.map(v, path, item_fn)
	if v == nil then return {}, nil end
	if not M.is_plain_table(v) or tablex.is_array(v) then
		return nil, M.err(path, 'must be a map keyed by id')
	end
	local out = {}
	local keys = tablex.sorted_keys(v)
	for i = 1, #keys do
		local id = keys[i]
		local sid, ierr = M.id(tostring(id), { M.path(path), id })
		if not sid then return nil, ierr end
		local rec, rerr = item_fn(sid, v[id], { M.path(path), sid })
		if not rec then return nil, rerr end
		out[sid] = rec
	end
	return out, nil
end

function M.copy_table_or_empty(v, path)
	if v == nil then return {}, nil end
	if not M.is_plain_table(v) then return nil, M.err(path, 'must be a plain table') end
	return M.copy(v), nil
end

function M.copy_optional_table(v, path)
	if v == nil then return nil, nil end
	if not M.is_plain_table(v) then return nil, M.err(path, 'must be a plain table') end
	return M.copy(v), nil
end

function M.check_allowed_fields(t, allowed, path)
	if not M.is_plain_table(t) then return nil, M.err(path, 'must be a plain table') end
	local ok = {}
	for i = 1, #allowed do ok[allowed[i]] = true end
	for k in pairs(t) do
		if not ok[k] then return nil, M.err({ M.path(path), k }, 'field is not part of devicecode.config/net/1') end
	end
	return true, nil
end

function M.count_map(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

function M.with_optional_extensions(out, rec, path)
	local metadata, merr = M.copy_optional_table(rec.metadata, { M.path(path), 'metadata' })
	if merr then return nil, merr end
	local extensions, eerr = M.copy_optional_table(rec.extensions, { M.path(path), 'extensions' })
	if eerr then return nil, eerr end
	out.metadata = metadata
	out.extensions = extensions
	return out, nil
end

return M
