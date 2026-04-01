-- services/fabric/transport_uart.lua
--
-- UART transport using a HAL-provided Stream capability.
--
-- HAL method:
--   open_serial_stream
-- request:
--   { ref = "uart-0" }
-- reply:
--   { ok = true, stream = <Stream>, info = { ... } }

local protocol = require 'services.fabric.protocol'
local op       = require 'fibers.op'

local M = {}
local UartTransport = {}
UartTransport.__index = UartTransport

function M.new(svc, cfg)
	cfg = cfg or {}
	return setmetatable({
		_svc            = svc,
		_cfg            = cfg,
		_stream         = nil,
		_info           = nil,
		_max_line_bytes = (type(cfg.max_line_bytes) == 'number' and cfg.max_line_bytes > 0)
			and math.floor(cfg.max_line_bytes)
			or 4096,
	}, UartTransport)
end

function UartTransport:open()
	local ref = self._cfg.serial_ref
	if type(ref) ~= 'string' or ref == '' then
		return nil, 'uart transport requires non-empty serial_ref'
	end

	local rep, err = self._svc:hal_call('open_serial_stream', {
		ref = ref,
	}, 5.0)

	if not rep then
		return nil, tostring(err)
	end
	if rep.ok ~= true then
		return nil, tostring(rep.err or 'open_serial_stream failed')
	end
	if type(rep.stream) ~= 'table' then
		return nil, 'open_serial_stream returned no stream capability'
	end

	self._stream = rep.stream
	self._info   = rep.info or { ref = ref }
	return true, nil
end

function UartTransport:close()
	local s = self._stream
	self._stream = nil
	self._info = nil

	if s and s.close_op then
		local ok, err = require('fibers').perform(s:close_op())
		return ok, err
	end
	return true, nil
end

function UartTransport:send_msg_op(msg)
	local s = assert(self._stream, 'uart transport is not open')
	return op.guard(function()
		local line, err = protocol.encode_line(msg)
		if not line then
			return op.always(nil, err)
		end
		if #line > self._max_line_bytes then
			return op.always(nil, 'frame_too_large')
		end
		return s:write_op(line, '\n'):wrap(function(n, werr)
			if n == nil then
				return nil, tostring(werr)
			end
			return true, nil
		end)
	end)
end

-- Framing only: returns raw line text.
function UartTransport:recv_line_op()
	local s = assert(self._stream, 'uart transport is not open')
	return s:read_line_op():wrap(function(line, err)
		if err ~= nil then
			return nil, tostring(err)
		end
		if line == nil then
			return nil, 'eof'
		end
		if #line > self._max_line_bytes then
			return nil, 'frame_too_large'
		end
		return line, nil
	end)
end

-- Kept for compatibility with any existing callers.
function UartTransport:recv_msg_op()
	return self:recv_line_op():wrap(function(line, err)
		if not line then
			return nil, err
		end
		local msg, derr = protocol.decode_line(line)
		if not msg then
			return nil, derr
		end
		return msg, nil
	end)
end

function UartTransport:stats()
	return {
		kind = 'uart',
		info = self._info,
	}
end

return M
