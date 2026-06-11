local terminate = require 'services.http.transport.terminate'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

function M.test_terminate_stream_uses_terminate_when_available()
	local reason
	local stream = {
		terminate = function (_, why) reason = why; return true end,
		close = function () error('close must not be used by terminate_stream', 0) end,
		shutdown = function () error('shutdown must not be used by terminate_stream', 0) end,
	}
	ok(terminate.terminate_stream(stream, 'done'))
	eq(reason, 'done')
end

function M.test_terminate_stream_takes_and_closes_underlying_socket()
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

function M.test_terminate_stream_does_not_use_graceful_fallbacks_when_socket_is_unavailable()
	local stream_close_called = false
	local stream_shutdown_called = false
	local stream = {
		connection = {},
		close = function () stream_close_called = true; return true end,
		shutdown = function () stream_shutdown_called = true; return true end,
	}
	ok(terminate.terminate_stream(stream, 'drop'))
	eq(stream_close_called, false)
	eq(stream_shutdown_called, false)
end

function M.test_terminate_server_uses_immediate_termination_or_listener_close()
	local reason
	ok(terminate.terminate_server({ terminate = function (_, why) reason = why; return true end }, 'down'))
	eq(reason, 'down')

	local closed
	ok(terminate.terminate_server({ close = function () closed = true; return true end }, 'down'))
	eq(closed, true)
end

function M.test_terminate_websocket_uses_terminate_when_available()
	local reason
	ok(terminate.terminate_websocket({ terminate = function (_, why) reason = why; return true end }, 'drop'))
	eq(reason, 'drop')
end

function M.test_terminate_websocket_uses_abnormal_zero_timeout_as_last_resort()
	local code, reason, timeout
	ok(terminate.terminate_websocket({ close = function (_, c, r, t) code, reason, timeout = c, r, t; return true end }, 'drop'))
	eq(code, 1006)
	eq(reason, 'drop')
	eq(timeout, 0)
end

function M.test_terminate_request_prefers_request_terminate()
	local reason
	ok(terminate.terminate_request({ terminate = function (_, why) reason = why; return true end }, 'drop'))
	eq(reason, 'drop')
end

function M.test_terminate_request_takes_and_closes_connection_socket_when_available()
	local socket_closed = false
	local cancel_called = false
	local req = {
		connection = {
			take_socket = function ()
				return { close = function () socket_closed = true; return true end }
			end,
		},
		cancel = function () cancel_called = true; return true end,
	}
	ok(terminate.terminate_request(req, 'drop'))
	eq(socket_closed, true)
	eq(cancel_called, false)
end

function M.test_terminate_request_uses_cancel_when_no_socket_exists_yet()
	local cancel_reason
	local close_called = false
	local shutdown_called = false
	ok(terminate.terminate_request({
		cancel = function (_, reason) cancel_reason = reason; return true end,
		close = function () close_called = true; return true end,
		shutdown = function () shutdown_called = true; return true end,
	}, 'drop'))
	eq(cancel_reason, 'drop')
	eq(close_called, false)
	eq(shutdown_called, false)
end

return M
