local mailbox = require 'fibers.mailbox'
local cjson = require 'cjson.safe'
local http_headers = require 'http.headers'

local M = {}

function M.principal(id, roles)
	return {
		id = id or 'user',
		kind = 'user',
		roles = roles or { 'admin' },
	}
end

function M.connect_factory(bus, calls)
	calls = calls or {}
	return function(principal, origin_extra)
		calls[#calls + 1] = {
			principal = principal,
			origin_extra = origin_extra,
		}
		return bus:connect({ principal = principal })
	end, calls
end

function M.seed_ui_state(conn)
	conn:retain({ 'cfg', 'net' }, {
		rev = 2,
		data = { schema = 'devicecode.net/1', answer = 42 },
	})
	conn:retain({ 'svc', 'alpha', 'meta' }, { role = 'alpha' })
	conn:retain({ 'svc', 'alpha', 'status' }, { state = 'running', ready = true, run_id = 'alpha-run-1' })
	conn:retain({ 'state', 'fabric' }, {
		kind = 'fabric.summary',
		component = 'summary',
		status = { desired = 1, live = 1 },
		links = { wan0 = true },
	})
	conn:retain({ 'state', 'fabric', 'link', 'wan0', 'session' }, {
		kind = 'fabric.link.session',
		status = { ready = true, established = true, generation = 3 },
	})
	conn:retain({ 'state', 'fabric', 'link', 'wan0', 'bridge' }, {
		kind = 'fabric.link.bridge',
		status = { connected = true },
	})
	conn:retain({ 'state', 'fabric', 'link', 'wan0', 'transfer' }, {
		kind = 'fabric.link.transfer',
		status = { idle = true },
	})
	conn:retain({ 'cap', 'fs', 'config', 'meta' }, { offerings = { read = true } })
	conn:retain({ 'dev', 'modem', 'm1', 'meta' }, { model = 'X1' })
end

function M.start_endpoint(scope, conn, topic, handler, opts)
	local ep = conn:bind(topic, opts)
	local ok, err = scope:spawn(function()
		while true do
			local req = ep:recv()
			if not req then return end
			handler(req)
		end
	end)
	assert(ok, tostring(err))
	return ep
end

function M.make_headers(tbl)
	local h = http_headers.new()
	for k, v in pairs(tbl or {}) do
		h:append(k, tostring(v))
	end
	return h
end

function M.fake_http_stream(opts)
	opts = opts or {}
	local req_headers = M.make_headers(opts.headers or {
		[':method'] = opts.method or 'GET',
		[':path'] = opts.path or '/',
	})
	local stream = {
		state = 'open',
		_req_headers = req_headers,
		_req_body = opts.body or '',
		_req_off = 1,
		_resp_headers = nil,
		_resp_chunks = {},
	}

	function stream:get_headers()
		return self._req_headers
	end

	function stream:get_body_as_string()
		return self._req_body
	end

	function stream:get_body_chars(n)
		n = tonumber(n) or #self._req_body
		if self._req_off > #self._req_body then return '' end
		local chunk = self._req_body:sub(self._req_off, self._req_off + n - 1)
		self._req_off = self._req_off + #chunk
		return chunk
	end

	function stream:write_headers(h, end_stream)
		self._resp_headers = h
		if end_stream then self.state = 'closed' end
		return true
	end

	function stream:write_chunk(chunk, end_stream)
		self._resp_chunks[#self._resp_chunks + 1] = chunk or ''
		if end_stream then self.state = 'closed' end
		return true
	end

	function stream:shutdown()
		self.state = 'closed'
		return true
	end

	function stream:status()
		return self._resp_headers and self._resp_headers:get(':status') or nil
	end

	function stream:header(name)
		return self._resp_headers and self._resp_headers:get(name) or nil
	end

	function stream:body()
		return table.concat(self._resp_chunks)
	end

	function stream:json()
		return cjson.decode(self:body())
	end

	return stream
end

function M.fake_ws()
	local tx, rx = mailbox.new(64, { full = 'reject_newest' })
	local ws = {
		sent = {},
		closed = false,
		_tx = tx,
		_rx = rx,
	}

	function ws:accept()
		return true
	end

	function ws:receive()
		local item, err = self._rx:recv()
		if item == nil then
			return nil, nil, err
		end
		return item.msg, item.opcode, item.err
	end

	function ws:send(txt)
		self.sent[#self.sent + 1] = txt
		return true
	end

	function ws:close()
		self.closed = true
		pcall(function() self._tx:close('closed') end)
		return true
	end

	function ws:inject_text(obj)
		local msg = type(obj) == 'string' and obj or assert(cjson.encode(obj))
		local ok, err = self._tx:send({ msg = msg, opcode = 'text' })
		assert(ok == true, tostring(err))
	end

	function ws:inject_frame(msg, opcode)
		local ok, err = self._tx:send({ msg = msg, opcode = opcode or 'text' })
		assert(ok == true, tostring(err))
	end

	function ws:disconnect(reason)
		pcall(function() self._tx:close(reason or 'closed') end)
	end

	function ws:sent_objects()
		local out = {}
		for i = 1, #self.sent do
			out[i] = cjson.decode(self.sent[i])
		end
		return out
	end

	return ws
end

function M.install_fake_websocket_module(fake_ws)
	local orig_ws = package.loaded['http.websocket']
	local orig_client = package.loaded['services.ui.transport.ws_client']
	package.loaded['http.websocket'] = {
		new_from_stream = function(stream)
			return stream._fake_ws or fake_ws, nil
		end,
	}
	package.loaded['services.ui.transport.ws_client'] = nil
	return function()
		package.loaded['http.websocket'] = orig_ws
		package.loaded['services.ui.transport.ws_client'] = orig_client
	end
end

return M
