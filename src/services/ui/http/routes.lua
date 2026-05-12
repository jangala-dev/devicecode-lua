-- services/ui/http/routes.lua
--
-- Pure route decoding for UI HTTP requests.

local M = {}

local function split_path(path)
	path = tostring(path or '/')
	local out = {}
	for part in path:gmatch('[^/]+') do
		out[#out + 1] = part
	end
	return out
end

local function method_of(ctx)
	if ctx and type(ctx.method) == 'function' then
		local ok, v = pcall(function () return ctx:method() end)
		if ok and v ~= nil then return string.upper(tostring(v)) end
	end
	return string.upper(tostring((ctx and (ctx.method or ctx.verb)) or 'GET'))
end

local function path_of(ctx)
	if ctx and type(ctx.path) == 'function' then
		local ok, v = pcall(function () return ctx:path() end)
		if ok and v ~= nil then return v end
	end
	return (ctx and (ctx.path or ctx.uri)) or '/'
end

function M.decode(ctx)
	local method = method_of(ctx)
	local parts = split_path(path_of(ctx))

	if #parts == 0 then
		return { kind = 'static', path = '/index.html' }
	end

	if parts[1] == 'events' and method == 'GET' then
		return { kind = 'sse', pattern = { '#' } }
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

	if parts[2] == 'update' and parts[3] == 'upload' and method == 'POST' then
		return { kind = 'upload' }
	end

	if parts[2] == 'call' and method == 'POST' then
		local topic = {}
		for i = 3, #parts do topic[#topic + 1] = parts[i] end
		return { kind = 'command', topic = topic }
	end

	return { kind = 'not_found' }
end

return M
