local terminate = require 'services.http.transport.terminate'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

function M.test_terminate_stream_prefers_shutdown_and_is_idempotent_shape()
	local calls = {}
	local stream = {
		shutdown = function () calls[#calls + 1] = 'shutdown'; return true end,
		close = function () calls[#calls + 1] = 'close'; return true end,
	}
	ok(terminate.terminate_stream(stream, 'done'))
	eq(calls[1], 'shutdown')
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

function M.test_terminate_request_prefers_immediate_shutdown()
	local calls = {}
	ok(terminate.terminate_request({
		shutdown = function () calls[#calls + 1] = 'shutdown'; return true end,
		close = function () calls[#calls + 1] = 'close'; return true end,
	}, 'drop'))
	eq(calls[1], 'shutdown')
	eq(calls[2], nil)
end

function M.test_terminate_request_falls_back_to_cancel_with_reason()
	local cancel_reason
	ok(terminate.terminate_request({
		cancel = function (_, reason) cancel_reason = reason; return true end,
	}, 'drop'))
	eq(cancel_reason, 'drop')
end

return M
