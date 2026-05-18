-- services/http/transport/tolerant_http1.lua
--
-- Lenient HTTP/1.0 client transport for devices whose embedded HTTP servers do
-- not produce responses accepted by lua-http. This module remains below the
-- services.http boundary; callers still use cap/http through services.http.sdk.

local op = require 'fibers.op'

local M = {}

local function require_socket(opts)
	if opts and opts.socket_module then return opts.socket_module end
	local ok, mod = pcall(require, 'cqueues.socket')
	if not ok then return nil, mod end
	return mod
end

local function lower(s)
	return tostring(s or ''):lower()
end

local Headers = {}
Headers.__index = Headers

local function new_headers(status, pairs)
	local self = setmetatable({
		_pairs = { { ':status', tostring(status or 200) } },
		_map = { [':status'] = tostring(status or 200) },
	}, Headers)
	for i = 1, #(pairs or {}) do
		local k = tostring(pairs[i][1] or '')
		local v = tostring(pairs[i][2] or '')
		self._pairs[#self._pairs + 1] = { k, v }
		self._map[lower(k)] = self._map[lower(k)] or v
	end
	return self
end

function Headers:get(name)
	return self._map[lower(name)]
end

function Headers:each()
	local i = 0
	return function ()
		i = i + 1
		local row = self._pairs[i]
		if row then return row[1], row[2] end
	end
end

local Stream = {}
Stream.__index = Stream

local function new_stream(body)
	return setmetatable({ _body = body or '', _off = 1, _closed = false }, Stream)
end

function Stream:get_next_chunk()
	if self._closed then return nil end
	if self._off > #self._body then return nil end
	local chunk = self._body:sub(self._off)
	self._off = #self._body + 1
	return chunk
end

function Stream:get_body_chars(n)
	if self._closed then return nil, 'closed' end
	n = tonumber(n) or 0
	if n <= 0 then return '' end
	local chunk = self._body:sub(self._off, self._off + n - 1)
	self._off = self._off + #chunk
	return chunk
end

function Stream:get_body_as_string()
	if self._closed then return nil, 'closed' end
	local body = self._body:sub(self._off)
	self._off = #self._body + 1
	return body
end

function Stream:shutdown()
	self._closed = true
	return true
end

function Stream:close()
	return self:shutdown()
end

local function body_from_iterator(iter)
	if iter == nil then return nil, nil end
	local out = {}
	while true do
		local chunk = iter()
		if chunk == nil then break end
		out[#out + 1] = tostring(chunk)
	end
	return table.concat(out), nil
end

local function header_pairs(headers)
	local out = {}
	for k, v in pairs(headers or {}) do
		if type(v) == 'table' then
			for i = 1, #v do out[#out + 1] = { k, v[i] } end
		else
			out[#out + 1] = { k, v }
		end
	end
	return out
end

local function has_header(pairs, name)
	local want = lower(name)
	for i = 1, #pairs do
		if lower(pairs[i][1]) == want then return true end
	end
	return false
end

local function build_request(args)
	local uri = args._uri or {}
	local path = uri.path or '/'
	local authority = uri.authority or uri.host or ''
	local method = args.method or 'GET'
	local body, berr = body_from_iterator(args._request_body)
	if berr then return nil, berr end

	local headers = {}
	for _, pair in ipairs(header_pairs(args.headers)) do
		headers[#headers + 1] = pair
	end
	if body ~= nil and not has_header(headers, 'Content-Length') then
		headers[#headers + 1] = { 'Content-Length', tostring(#body) }
	end

	local lines = {
		('%s %s HTTP/1.0\r\n'):format(method, path),
		('Host: %s\r\n'):format(authority),
		'Accept: */*\r\n',
		'Connection: close\r\n',
	}
	for i = 1, #headers do
		lines[#lines + 1] = ('%s: %s\r\n'):format(tostring(headers[i][1]), tostring(headers[i][2] or ''))
	end
	lines[#lines + 1] = '\r\n'
	if body ~= nil then lines[#lines + 1] = body end
	return table.concat(lines), nil
end

local function parse_response(raw)
	raw = tostring(raw or '')
	local head, body = raw:match('^(.-)\r\n\r\n(.*)$')
	if not head then head, body = raw:match('^(.-)\n\n(.*)$') end
	if not head then
		local i = raw:find('{', 1, true)
		if i then return new_headers(200), new_stream(raw:sub(i)) end
		return nil, 'invalid_http_response'
	end

	local lines = {}
	for line in head:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
	local status = lines[1] and lines[1]:match('^HTTP/%S+%s+(%d+)') or nil
	status = tonumber(status) or 200
	local pairs = {}
	for i = 2, #lines do
		local k, v = lines[i]:match('^([^:]+):%s*(.*)$')
		if k and k ~= '' then pairs[#pairs + 1] = { k, v or '' } end
	end
	return new_headers(status, pairs), new_stream(body or '')
end

local function read_all(sock)
	local chunks = {}
	while true do
		local ok, buf, err, part = pcall(function () return sock:read(4096) end)
		if not ok then return nil, buf end
		if buf and #buf > 0 then
			chunks[#chunks + 1] = buf
		elseif part and #part > 0 then
			chunks[#chunks + 1] = part
		end
		if not buf then
			if err and err ~= 'eof' then return nil, 'read error: ' .. tostring(err) end
			break
		end
	end
	return table.concat(chunks), nil
end

local function write_request(sock, request)
	local ok, wres, werr = pcall(function () return sock:write(request) end)
	if not ok then return nil, wres end
	if not wres then return nil, werr end
	local fok, ferr = pcall(function () return sock:flush() end)
	if not fok then return nil, ferr end
	return true, nil
end

function M.open_exchange_op(driver, args, opts)
	opts = opts or {}
	return op.guard(function ()
		local socket, serr = require_socket(opts)
		if not socket then return op.always(nil, serr) end
		local active = { socket = nil }
		return driver:run_op('http.tolerant_http1.open_exchange', function ()
			local uri = args._uri or {}
			if uri.scheme ~= nil and uri.scheme ~= 'http' then return nil, 'unsupported_scheme' end
			local port = uri.port or ((uri.scheme == 'https') and 443 or 80)
			local sock, err = socket.connect(uri.host, port)
			if not sock then return nil, err or 'connect_failed' end
			active.socket = sock
			if sock.settimeout then sock:settimeout(args.timeout_s or opts.backend_timeout or opts.timeout) end
			if sock.setmode then sock:setmode('b', 'b') end

			local request, rerr = build_request(args)
			if not request then return nil, rerr end
			local ok, werr = write_request(sock, request)
			if not ok then return nil, 'write/flush failed: ' .. tostring(werr) end
			local raw, read_err = read_all(sock)
			if sock.close then sock:close() end
			active.socket = nil
			if not raw then return nil, read_err end
			return parse_response(raw)
		end, {
			on_active_abort = function (reason)
				local sock = active.socket
				active.socket = nil
				if sock and sock.close then pcall(function () sock:close(reason or 'aborted') end) end
			end,
		})
	end)
end

M._test = {
	build_request = build_request,
	parse_response = parse_response,
	new_stream = new_stream,
}

return M
