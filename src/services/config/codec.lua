-- services/config/codec.lua
--
-- Pure-ish codec helpers for the config service.

local cjson = require 'cjson.safe'

local M = {}

M.JSON_NULL = cjson.null

function M.is_plain_table(x)
	return type(x) == 'table' and getmetatable(x) == nil
end

function M.strip_nulls(x, seen)
	if x == M.JSON_NULL then return nil end
	if type(x) ~= 'table' then return x end
	if getmetatable(x) ~= nil then return x end

	seen = seen or {}
	if seen[x] then return x end
	seen[x] = true

	for k, v in pairs(x) do
		local nv = M.strip_nulls(v, seen)
		if nv == nil then
			x[k] = nil
		else
			x[k] = nv
		end
	end
	return x
end

function M.deepcopy_plain(x, seen)
	if type(x) ~= 'table' then
		return x
	end
	if getmetatable(x) ~= nil then
		error('deepcopy_plain: metatables are not supported', 2)
	end

	seen = seen or {}
	if seen[x] then
		return seen[x]
	end

	local out = {}
	seen[x] = out

	for k, v in pairs(x) do
		local nk = M.deepcopy_plain(k, seen)
		local nv = M.deepcopy_plain(v, seen)
		out[nk] = nv
	end

	return out
end

function M.decode_blob_strict(blob)
	local decoded, jerr = cjson.decode(blob)
	if decoded == nil then
		return nil, 'json_decode_failed: ' .. tostring(jerr)
	end
	if not M.is_plain_table(decoded) then
		return nil, 'invalid_shape: root must be a table'
	end

	M.strip_nulls(decoded)

	local out = {}
	for svc, rec in pairs(decoded) do
		if type(svc) ~= 'string' or svc == '' then
			return nil, 'invalid_shape: service key must be non-empty string'
		end
		if not M.is_plain_table(rec) then
			return nil, 'invalid_shape: record must be a table for ' .. svc
		end
		if type(rec.rev) ~= 'number' then
			return nil, 'invalid_shape: rev must be a number for ' .. svc
		end
		if not M.is_plain_table(rec.data) then
			return nil, 'invalid_shape: data must be a table for ' .. svc
		end

		if type(rec.data.schema) ~= 'string' or rec.data.schema == '' then
			return nil, 'invalid_shape: data.schema must be a non-empty string for ' .. svc
		end

		out[svc] = {
			rev  = math.floor(rec.rev),
			data = M.deepcopy_plain(rec.data),
		}
	end

	return out, nil
end

function M.encode_blob(current)
	local encoded, err = cjson.encode(current)
	if encoded == nil then
		return nil, 'json_encode_failed: ' .. tostring(err)
	end
	return encoded, nil
end

return M
