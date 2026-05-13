local fibers = require 'fibers'
local websocket = require 'services.http.websocket'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

local function fake_driver()
	return {
		run_op = function (_, _, fn)
			return fibers.guard(function () return fibers.always(fn()) end)
		end,
	}
end

function M.test_client_connect_and_send_are_driver_jobs()
	fibers.run(function ()
		local raw = {
			connected = false,
			sent = nil,
			connect = function (self) self.connected = true; return true end,
			send = function (self, data, opcode) self.sent = { data, opcode }; return true end,
			receive = function () return 'reply', 'text' end,
			close = function () return true end,
		}
		local module = {
			new_from_uri = function (uri)
				eq(uri, 'ws://example.test/ws')
				return raw
			end,
		}
		local ws = ok(fibers.perform(websocket.connect_op(fake_driver(), {
			uri = 'ws://example.test/ws',
		}, { websocket_module = module })))
		ok(raw.connected, 'connect should run')
		ok(fibers.perform(ws:send_op('hello', 'text')))
		eq(raw.sent[1], 'hello')
		eq(raw.sent[2], 'text')
		local data, opcode = fibers.perform(ws:receive_op())
		eq(data, 'reply')
		eq(opcode, 'text')
	end)
end


function M.test_client_connect_applies_validated_headers_before_connect()
	fibers.run(function ()
		local raw = {
			headers = {
				values = {},
				upsert = function (self, k, v) self.values[k] = v end,
				append = function (self, k, v) self.values[k] = v end,
			},
			connect = function (self)
				eq(self.headers.values['x-auth'], 'token', 'headers must be applied before websocket connect')
				return true
			end,
			send = function () return true end,
			receive = function () return nil, 'closed' end,
			close = function () return true end,
		}
		local module = {
			new_from_uri = function (uri)
				eq(uri, 'ws://example.test/ws')
				return raw
			end,
		}
		local ws = ok(fibers.perform(websocket.connect_op(fake_driver(), {
			uri = 'ws://example.test/ws',
			headers = { ['x-auth'] = 'token' },
		}, { websocket_module = module })))
		ok(ws)
	end)
end

return M
