local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local sleep   = require 'fibers.sleep'
local op      = require 'fibers.op'

local M = {}

local function new_transport()
	local read_tx, read_rx = mailbox.new(128, { full = 'reject_newest' })
	local transport = {
		_read_tx = read_tx,
		_read_rx = read_rx,
		_writes = {},
		_fail_writes = {},
		_closed = false,
	}

	function transport:inject_line(line)
		local ok, err = self._read_tx:send({ kind = 'line', line = line })
		assert(ok == true, tostring(err))
	end

	function transport:inject_read_error(err)
		local ok, reason = self._read_tx:send({ kind = 'err', err = err or 'read_failed' })
		assert(ok == true, tostring(reason))
	end

	function transport:fail_next_write(err)
		self._fail_writes[#self._fail_writes + 1] = err or 'write_failed'
	end

	function transport:read_line_op(timeout_s)
		timeout_s = timeout_s or 0.05
		return fibers.named_choice({
			item = self._read_rx:recv_op(),
			timeout = sleep.sleep_op(timeout_s):wrap(function () return { kind = 'timeout' } end),
		}):wrap(function (which, item)
			if which == 'timeout' then
				return nil, 'timeout'
			end
			if not item then
				return nil, 'closed'
			end
			if item.kind == 'err' then
				return nil, item.err
			end
			return item.line, nil
		end)
	end

	function transport:write_line_op(line)
		if self._closed then
			return op.always(nil, 'closed')
		end
		if #self._fail_writes > 0 then
			local err = table.remove(self._fail_writes, 1)
			return op.always(nil, err)
		end
		self._writes[#self._writes + 1] = line
		return op.always(true, nil)
	end

	function transport:writes()
		local out = {}
		for i = 1, #self._writes do out[i] = self._writes[i] end
		return out
	end

	function transport:write_count()
		return #self._writes
	end

	function transport:close()
		self._closed = true
		pcall(function () self._read_tx:close('closed') end)
		return true
	end

	return transport
end

local function wait_write_count(transport, n, timeout)
	timeout = timeout or 1.0
	local deadline = fibers.now() + timeout
	while fibers.now() < deadline do
		if transport:write_count() >= n then
			return true
		end
		sleep.sleep(0.005)
	end
	return transport:write_count() >= n
end

local function decode_writes(transport, protocol_mod)
	local protocol = protocol_mod or require 'services.fabric.protocol'
	local out = {}
	for i, line in ipairs(transport:writes()) do
		local frame, err = protocol.decode_line(line)
		assert(frame ~= nil, tostring(err))
		out[i] = frame
	end
	return out
end

local function recv_mailbox(rx, timeout)
	timeout = timeout or 1.0
	local which, item, err = fibers.perform(fibers.named_choice({
		item = rx:recv_op(),
		timeout = sleep.sleep_op(timeout):wrap(function () return nil, 'timeout' end),
	}))
	if which == 'timeout' then
		return nil, 'timeout'
	end
	return item, err
end

function M.new_transport()
	return new_transport()
end

function M.wait_write_count(transport, n, timeout)
	return wait_write_count(transport, n, timeout)
end

function M.decode_writes(transport, protocol_mod)
	return decode_writes(transport, protocol_mod)
end

function M.recv_mailbox(rx, timeout)
	return recv_mailbox(rx, timeout)
end

return M
