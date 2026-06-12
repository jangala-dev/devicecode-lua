local terminate = require 'services.http.transport.terminate'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

function M.test_terminate_stream_takes_and_closes_underlying_socket_before_graceful_methods()
	local socket_closed = false
	local stream_close_called = false
	local stream_shutdown_called = false
	local stream = {
		connection = {
			take_socket = function ()
				return { close = function () socket_closed = true; return true end }
			end,
		},
		close = function () stream_close_called = true; return true end,
		shutdown = function () stream_shutdown_called = true; return true end,
	}
	ok(terminate.terminate_stream(stream, 'drop'))
	eq(socket_closed, true)
	eq(stream_close_called, false)
	eq(stream_shutdown_called, false)
end

function M.test_terminate_stream_prefers_terminate_then_close_over_shutdown_when_socket_take_unavailable()
	local calls = {}
	local stream = {
		terminate = function (_, reason) calls[#calls + 1] = 'terminate:' .. tostring(reason); return true end,
		close = function () calls[#calls + 1] = 'close'; return true end,
		shutdown = function () calls[#calls + 1] = 'shutdown'; return true end,
	}
	ok(terminate.terminate_stream(stream, 'done'))
	eq(calls[1], 'terminate:done')
	eq(calls[2], nil)
end

function M.test_terminate_stream_falls_back_to_close_before_shutdown()
	local calls = {}
	local stream = {
		close = function () calls[#calls + 1] = 'close'; return true end,
		shutdown = function () calls[#calls + 1] = 'shutdown'; return true end,
	}
	ok(terminate.terminate_stream(stream, 'done'))
	eq(calls[1], 'close')
	eq(calls[2], nil)
end

function M.test_terminate_server_uses_immediate_termination()
	local closed
	ok(terminate.terminate_server({ close = function () closed = true; return true end }, 'down'))
	eq(closed, true)
end

function M.test_terminate_websocket_uses_abnormal_immediate_termination()
	local code, reason, timeout
	ok(terminate.terminate_websocket({ close = function (_, c, r, t) code, reason, timeout = c, r, t; return true end }, 'drop'))
	eq(code, 1006)
	eq(reason, 'drop')
	eq(timeout, 0)
end

function M.test_terminate_request_takes_and_closes_underlying_socket_when_present()
	local socket_closed = false
	local request = {
		connection = {
			take_socket = function () return { close = function () socket_closed = true; return true end } end,
		},
		cancel = function () error('cancel must not be used when socket take succeeds', 0) end,
		close = function () error('close must not be used when socket take succeeds', 0) end,
		shutdown = function () error('shutdown must not be used when socket take succeeds', 0) end,
	}
	ok(terminate.terminate_request(request, 'drop'))
	eq(socket_closed, true)
end

function M.test_terminate_request_prefers_terminate_when_available()
	local calls = {}
	ok(terminate.terminate_request({
		terminate = function (_, reason) calls[#calls + 1] = 'terminate:' .. tostring(reason); return true end,
		cancel = function () calls[#calls + 1] = 'cancel'; return true end,
	}, 'drop'))
	eq(calls[1], 'terminate:drop')
	eq(calls[2], nil)
end

function M.test_terminate_request_falls_back_to_cancel_before_graceful_methods()
	local calls = {}
	ok(terminate.terminate_request({
		cancel = function (_, reason) calls[#calls + 1] = 'cancel:' .. tostring(reason); return true end,
		close = function () calls[#calls + 1] = 'close'; return true end,
		shutdown = function () calls[#calls + 1] = 'shutdown'; return true end,
	}, 'drop'))
	eq(calls[1], 'cancel:drop')
	eq(calls[2], nil)
end

return M
