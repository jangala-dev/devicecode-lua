-- services/http/headers.lua
--
-- Small boundary around lua-http header objects.  The rest of the service should
-- not hand-build backend header objects or depend on their metatable shape.

local M = {}

local function require_headers()
	local ok, mod = pcall(require, 'http.headers')
	if not ok then return nil, mod end
	return mod
end

local function new_raw()
	local headers, err = require_headers()
	if not headers then return nil, err end
	return headers.new()
end

local function append_all(h, values)
	for _, item in ipairs(values) do
		if type(item) == 'table' then
			h:append(tostring(item[1]), tostring(item[2] or ''))
		else
			return nil, 'invalid_header_value'
		end
	end
	return true
end

local function apply_table(h, tbl)
	for k, v in pairs(tbl or {}) do
		if type(k) == 'number' then
			if type(v) ~= 'table' then return nil, 'invalid_header_pair' end
			h:append(tostring(v[1]), tostring(v[2] or ''))
		elseif type(v) == 'table' then
			for _, vv in ipairs(v) do h:append(tostring(k), tostring(vv)) end
		else
			h:append(tostring(k), tostring(v))
		end
	end
	return true
end

function M.is_backend_headers(v)
	return type(v) == 'table' and type(v.get) == 'function' and type(v.append) == 'function'
end

function M.new(fields)
	local h, err = new_raw()
	if not h then return nil, err end
	local ok, aerr
	if type(fields) == 'table' and fields[1] ~= nil and type(fields[1]) == 'table' then
		ok, aerr = append_all(h, fields)
	else
		ok, aerr = apply_table(h, fields or {})
	end
	if not ok then return nil, aerr end
	return h
end

function M.request(method, path, authority, scheme, fields)
	local h, err = M.new(fields or {})
	if not h then return nil, err end
	if method ~= nil then h:upsert(':method', tostring(method)) end
	if path ~= nil then h:upsert(':path', tostring(path)) end
	if authority ~= nil then h:upsert(':authority', tostring(authority)) end
	if scheme ~= nil then h:upsert(':scheme', tostring(scheme)) end
	return h
end

function M.status(status, fields)
	local h, err = M.new(fields or {})
	if not h then return nil, err end
	h:upsert(':status', tostring(status or 200))
	return h
end

function M.clone(headers)
	if headers and type(headers.clone) == 'function' then return headers:clone() end
	return M.new(M.to_table(headers))
end

function M.get_one(headers, name)
	if not headers or type(headers.get) ~= 'function' then return nil end
	return headers:get(string.lower(tostring(name)))
end

function M.get_all(headers, name)
	local out = {}
	if not headers then return out end
	name = string.lower(tostring(name))
	if type(headers.each) == 'function' then
		for k, v in headers:each() do
			if tostring(k):lower() == name then out[#out + 1] = v end
		end
		return out
	end
	local v = M.get_one(headers, name)
	if v ~= nil then out[1] = v end
	return out
end

function M.to_table(headers)
	local out = {}
	if not headers then return out end
	if type(headers.each) == 'function' then
		for k, v in headers:each() do
			k = tostring(k)
			if out[k] == nil then
				out[k] = v
			elseif type(out[k]) == 'table' then
				out[k][#out[k] + 1] = v
			else
				out[k] = { out[k], v }
			end
		end
		return out
	end
	for k, v in pairs(headers) do out[k] = v end
	return out
end

function M.to_pairs(headers)
	local out = {}
	if not headers then return out end
	if type(headers.each) == 'function' then
		for k, v in headers:each() do out[#out + 1] = { k, v } end
		return out
	end
	for k, v in pairs(headers) do
		if type(v) == 'table' then
			for _, vv in ipairs(v) do out[#out + 1] = { k, vv } end
		else
			out[#out + 1] = { k, v }
		end
	end
	return out
end

return M
