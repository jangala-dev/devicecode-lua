-- services/http/transport/legacy_http1_close.lua
--
-- Strict, bounded HTTP/1.0 close-delimited client transport for legacy embedded
-- devices whose response headers are rejected by lua-http.  This is not a raw
-- socket escape hatch: it is selected explicitly by response_parser =
-- "legacy-http1-close" and is still admitted through services.http policy.

local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local socket = require 'fibers.io.socket'
local headers_mod = require 'services.http.transport.headers'

local M = {}

local Stream = {}
Stream.__index = Stream

local function new_stream(body)
	return setmetatable({ body = body or '', off = 1, closed = false }, Stream)
end

function Stream:get_next_chunk()
	if self.closed then return nil end
	if self.off > #self.body then return nil end
	local chunk = self.body:sub(self.off)
	self.off = #self.body + 1
	return chunk
end

function Stream:get_body_chars(n)
	if self.closed then return nil, 'closed' end
	n = tonumber(n) or 0
	if n <= 0 then return '' end
	local chunk = self.body:sub(self.off, self.off + n - 1)
	self.off = self.off + #chunk
	return chunk
end

function Stream:get_body_as_string()
	if self.closed then return nil, 'closed' end
	local body = self.body:sub(self.off)
	self.off = #self.body + 1
	return body
end

function Stream:shutdown()
	self.closed = true
	return true
end

function Stream:close()
	return self:shutdown()
end

local function target_from_uri(parsed)
	-- The HTTP policy parser keeps the original URI as well as the normalised
	-- path.  Use the original URI to reconstruct the request target so that the
	-- query string is never lost before the legacy transport reaches CGI-style
	-- endpoints such as /cgi/get.cgi?cmd=panel_info.  Some embedded servers do
	-- not return promptly for /cgi/get.cgi without cmd=..., which makes this a
	-- correctness issue rather than a cosmetic one.
	local uri = parsed and parsed.uri
	if type(uri) == 'string' then
		local target = uri:match('^%a[%w+.-]*://[^/]*(/.*)$')
		if target and target ~= '' then return target end
	end
	local path = parsed and parsed.path or '/'
	if path == '' then path = '/' end
	return path
end

local function has_header(headers, name)
	name = tostring(name or ''):lower()
	for k in pairs(headers or {}) do
		if tostring(k):lower() == name then return true end
	end
	return false
end

local function collect_request_body(args, max_bytes)
	local source = args._request_source
	local iter = args._request_body
	if source == nil and iter == nil then return '', nil end
	max_bytes = tonumber(max_bytes) or (1024 * 1024)
	if max_bytes <= 0 then return nil, 'invalid_max_request_bytes' end
	local out, total = {}, 0
	local function add(chunk)
		chunk = tostring(chunk)
		total = total + #chunk
		if total > max_bytes then return nil, 'request_body_too_large' end
		out[#out + 1] = chunk
		return true, nil
	end
	if source ~= nil then
		while true do
			local chunk, err = fibers.perform(source:read_chunk_op(65536))
			if err then return nil, err end
			if chunk == nil then break end
			local ok, aerr = add(chunk)
			if not ok then return nil, aerr end
		end
	else
		while true do
			local chunk = iter()
			if chunk == nil then break end
			local ok, aerr = add(chunk)
			if not ok then return nil, aerr end
		end
	end
	return table.concat(out), nil
end

local function render_request(args, body)
	body = body or ''
	local uri = args._uri or {}
	local method = tostring(args.method or 'GET'):upper()
	local lines = {
		('%s %s HTTP/1.0'):format(method, target_from_uri(uri)),
	}
	local headers = args.headers or {}
	lines[#lines + 1] = 'Host: ' .. tostring(uri.authority or uri.host or '')
	lines[#lines + 1] = 'Connection: close'
	if body ~= '' then lines[#lines + 1] = 'Content-Length: ' .. tostring(#body) end
	for k, v in pairs(headers) do
		local lk = tostring(k):lower()
		-- The legacy transport owns hop-by-hop and length framing.  Policy has
		-- already rejected CR/LF injection; avoid duplicate or contradictory fields.
		if lk ~= 'host' and lk ~= 'connection' and lk ~= 'content-length' and lk ~= 'transfer-encoding' then
			lines[#lines + 1] = tostring(k) .. ': ' .. tostring(v)
		end
	end
	lines[#lines + 1] = ''
	lines[#lines + 1] = body or ''
	return table.concat(lines, '\r\n')
end

local function parse_header_block(header_block)
	header_block = tostring(header_block or '')
	local status_line = header_block:match('^([^\r\n]+)') or ''
	local status = status_line:match('^HTTP/%d+%.%d+%s+(%d%d%d)')
	if not status then return nil, nil, 'invalid_status_line: ' .. status_line end
	local pairs, content_length = {}, nil
	for line in header_block:gmatch('[^\r\n]+') do
		if line ~= status_line then
			local k, v = line:match('^([^:]+):%s*(.*)$')
			if k and k ~= '' then
				local lk = tostring(k):lower()
				v = v or ''
				if lk == 'transfer-encoding' and tostring(v):lower() ~= 'identity' then
					return nil, nil, 'unsupported_transfer_encoding'
				end
				if lk == 'content-length' then
					content_length = tonumber(v)
					if content_length == nil or content_length < 0 then return nil, nil, 'invalid_content_length' end
				end
				-- Store normal header names in lower case.  The rest of the
				-- HTTP service uses lower-case lookups at the boundary, and
				-- http.headers:get() is not guaranteed to perform
				-- case-insensitive lookup for hand-built headers.
				pairs[#pairs + 1] = { lk, v }
			end
		end
	end
	local headers, herr = headers_mod.status(status, pairs)
	if not headers then return nil, nil, herr end
	return headers, content_length, nil
end

local function parse_response(raw)
	raw = tostring(raw or '')
	local header_block, response_body = raw:match('^(.-\r\n\r\n)(.*)$')
	if not header_block then header_block, response_body = raw:match('^(.-\n\n)(.*)$') end
	if not header_block then return nil, nil, 'no_header_separator' end
	local headers, _content_length, err = parse_header_block(header_block)
	if not headers then return nil, nil, err end
	return headers, new_stream(response_body or ''), nil
end

local function find_header_separator(raw)
	local a, b = raw:find('\r\n\r\n', 1, true)
	if a then return a, b end
	a, b = raw:find('\n\n', 1, true)
	return a, b
end

local function read_some_bounded(stream, want)
	local chunk, err = fibers.perform(stream:read_some_op(want))
	if err then return nil, err end
	return chunk, nil
end

local function read_response_bounded(stream, max_bytes, method)
	max_bytes = tonumber(max_bytes) or 0
	if max_bytes <= 0 then return nil, nil, 'invalid_max_response_bytes' end

	local chunks, total = {}, 0
	local header_start, header_end
	while not header_end do
		local remaining = max_bytes - total
		if remaining <= 0 then return nil, nil, 'response_too_large' end
		local chunk, err = read_some_bounded(stream, math.min(4096, remaining))
		if err then return nil, nil, err end
		if chunk == nil then return nil, nil, 'connection_closed_before_headers' end
		if chunk ~= '' then
			total = total + #chunk
			if total > max_bytes then return nil, nil, 'response_too_large' end
			chunks[#chunks + 1] = chunk
			local raw = table.concat(chunks)
			header_start, header_end = find_header_separator(raw)
			if header_end then
				local header_block = raw:sub(1, header_end)
				local body = raw:sub(header_end + 1)
				local headers, content_length, perr = parse_header_block(header_block)
				if not headers then return nil, nil, perr end

				if tostring(method or 'GET'):upper() == 'HEAD' then
					return headers, new_stream(''), nil
				end

				if content_length ~= nil then
					if content_length < 0 then return nil, nil, 'invalid_content_length' end
					while #body < content_length do
						remaining = max_bytes - total
						if remaining <= 0 then return nil, nil, 'response_too_large' end
						local need = math.min(content_length - #body, 4096, remaining)
						local more, rerr = read_some_bounded(stream, need)
						if rerr then return nil, nil, rerr end
						if more == nil then return nil, nil, 'connection_closed_before_body_complete' end
						if more ~= '' then
							total = total + #more
							if total > max_bytes then return nil, nil, 'response_too_large' end
							body = body .. more
						end
					end
					return headers, new_stream(body:sub(1, content_length)), nil
				end

				while true do
					remaining = max_bytes - total
					if remaining <= 0 then return nil, nil, 'response_too_large' end
					local more, rerr = read_some_bounded(stream, math.min(4096, remaining))
					if rerr then return nil, nil, rerr end
					if more == nil then break end
					if more ~= '' then
						total = total + #more
						if total > max_bytes then return nil, nil, 'response_too_large' end
						body = body .. more
					end
				end
				return headers, new_stream(body), nil
			end
		end
	end
end

local function close_stream(stream)
	if not stream then return end
	if stream.close_op then fibers.perform(stream:close_op())
	elseif stream.close then stream:close() end
end

local function open_once(args, opts, active)
	local uri = args._uri or {}
	if uri.scheme ~= 'http' then return nil, nil, 'unsupported_scheme' end
	local body, berr = collect_request_body(args, opts.max_request_body or opts.max_request_body_bytes or 1024 * 1024)
	if body == nil then return nil, nil, berr end
	local stream, serr = socket.connect_inet(uri.host, uri.port or 80)
	if not stream then return nil, nil, serr end
	if active then active.stream = stream end
	local owned = true
	local function close()
		if owned then
			owned = false
			if active then active.stream = nil end
			close_stream(stream)
		end
	end
	local ok, werr = fibers.perform(stream:write_op(render_request(args, body)))
	if not ok then close(); return nil, nil, werr end
	if stream.flush_op then fibers.perform(stream:flush_op()) end
	local response_headers, body_stream, rerr = read_response_bounded(
		stream,
		args.max_response_bytes or 1048576,
		args.method
	)
	close()
	if not response_headers then return nil, nil, rerr end
	return response_headers, body_stream, nil
end

function M.open_exchange_op(_driver, args, opts)
	opts = opts or {}
	return op.guard(function ()
		local active = { stream = nil }
		local result = fibers.run_scope_op(function (scope)
			scope:finally(function (_, status, primary)
				local stream = active.stream
				active.stream = nil
				close_stream(stream)
			end)
			return open_once(args, opts, active)
		end):wrap(function (status, _report, a, b, c)
			if status == 'ok' then return a, b or c end
			return nil, nil, a or status
		end)
		return op.named_choice({
			result = result,
			timeout = sleep.sleep_op(args.timeout_s),
		}):wrap(function (which, a, b, c)
			if which == 'timeout' then
				local stream = active.stream
				active.stream = nil
				close_stream(stream)
				return nil, 'timeout'
			end
			return a, b or c
		end)
	end)
end

M._test = {
	render_request = render_request,
	parse_response = parse_response,
	read_response_bounded = read_response_bounded,
	new_stream = new_stream,
}

return M
