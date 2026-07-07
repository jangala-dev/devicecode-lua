-- services/ui/http/routes.lua
--
-- Pure route decoding for UI HTTP requests.

local safe = require 'coxpcall'

local M = {}

local function split_path(path)
	path = tostring(path or '/')
	path = path:match('^([^?#]*)') or path
	local out = {}
	for part in path:gmatch('[^/]+') do
		out[#out + 1] = part
	end
	return out
end

local function query_flag(path, name)
	local query = tostring(path or ''):match('%?([^#]*)')
	if not query then return false end
	for pair in query:gmatch('[^&]+') do
		local key, value = pair:match('^([^=]*)=?(.*)$')
		if key == name then
			value = tostring(value or ''):lower()
			return value == '' or value == '1' or value == 'true' or value == 'yes'
		end
	end
	return false
end

local function method_of(ctx)
	if ctx and type(ctx.method) == 'function' then
		local ok, v = safe.pcall(function () return ctx:method() end)
		if ok and v ~= nil then return string.upper(tostring(v)) end
	end
	return string.upper(tostring((ctx and (ctx.method or ctx.verb)) or 'GET'))
end

local function header_one(headers, name)
	if not headers then return nil end
	if type(headers.get) == 'function' then
		local ok, v = safe.pcall(function () return headers:get(string.lower(name)) end)
		if ok and v ~= nil then return v end
	end
	if type(headers) == 'table' then
		return headers[name] or headers[string.lower(name)] or headers[string.upper(name)]
	end
	return nil
end

local function path_of(ctx)
	local header_path = ctx and header_one(ctx.headers, ':path')
	if header_path ~= nil then return header_path end
	if ctx and type(ctx.path) == 'function' then
		local ok, v = safe.pcall(function () return ctx:path() end)
		if ok and v ~= nil then return v end
	end
	return (ctx and (ctx.path or ctx.uri)) or '/'
end

function M.decode(ctx)
	local method = method_of(ctx)
	local path = path_of(ctx)
	local parts = split_path(path)

	if #parts == 0 then
		return { kind = 'static', path = '/index.html' }
	end

	if parts[1] == 'events' and method == 'GET' then
		return { kind = 'sse' }
	end

	if parts[1] ~= 'api' then
		return { kind = 'static', path = '/' .. table.concat(parts, '/') }
	end

	if parts[2] == 'login' and method == 'POST' then
		return { kind = 'login' }
	end

	if parts[2] == 'session' then
		if method == 'GET' then return { kind = 'session_get' } end
		if method == 'DELETE' or method == 'POST' then return { kind = 'logout' } end
	end

	if parts[2] == 'local-ui' and parts[3] == 'bootstrap' and method == 'GET' then
		return { kind = 'local_ui_bootstrap' }
	end

	if parts[2] == 'gsm' and parts[3] == 'apns' and parts[4] == 'custom' then
		if method == 'GET' then return { kind = 'gsm_apns_get' } end
		if method == 'PUT' then return { kind = 'gsm_apns_put' } end
	end

	if parts[2] == 'diagnostics' and method == 'GET' then
		return { kind = 'diagnostics_stub' }
	end

	if parts[2] == 'state' and method == 'GET' then
		local topic = {}
		for i = 3, #parts do topic[#topic + 1] = parts[i] end
		if #topic == 0 then
			return { kind = 'read', query = 'all' }
		end
		return { kind = 'read', query = 'topic', topic = topic }
	end

	if parts[2] == 'services' and method == 'GET' then
		return { kind = 'read', query = 'services' }
	end

	if parts[2] == 'fabric' and method == 'GET' then
		return { kind = 'read', query = 'fabric' }
	end


	if parts[2] == 'logs' and method == 'GET' then
		if parts[3] == 'follow' or parts[3] == 'tail' then
			return { kind = 'logs_follow' }
		end
		return { kind = 'logs_query', boot = query_flag(path, 'boot') }
	end

	if parts[2] == 'monitor' and parts[3] == 'profile' and method == 'POST' then
		return { kind = 'monitor_profile' }
	end

	if parts[2] == 'update' and method == 'GET' then
		if parts[3] == nil or parts[3] == 'status' then
			return { kind = 'read', query = 'update_status' }
		end
	end

	if parts[2] == 'update' and parts[3] == 'upload' and method == 'POST' then
		return { kind = 'upload' }
	end

	if parts[2] == 'update' and parts[3] == 'commit' and method == 'POST' then
		return { kind = 'update_commit' }
	end

	if parts[2] == 'call' and method == 'POST' then
		local topic = {}
		for i = 3, #parts do topic[#topic + 1] = parts[i] end
		return { kind = 'command', topic = topic }
	end

	return { kind = 'not_found' }
end

return M
