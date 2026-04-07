local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local op      = require 'fibers.op'

local M = {}

local Endpoint = {}
Endpoint.__index = Endpoint

local function flush_complete_lines(dst)
	while true do
		local i = dst._inbuf:find('\n', 1, true)
		if not i then
			return true, nil
		end

		local line = dst._inbuf:sub(1, i - 1)
		dst._inbuf = dst._inbuf:sub(i + 1)

		local ok, reason = dst._line_tx:send(line)
		if ok ~= true then
			if ok == nil then
				return nil, 'closed'
			end
			return nil, tostring(reason or 'full')
		end
	end
end

function Endpoint:write_op(...)
	local parts = {}
	for i = 1, select('#', ...) do
		parts[i] = tostring(select(i, ...))
	end
	local data = table.concat(parts)

	return op.guard(function()
		if self._closed then
			return op.always(nil, 'closed')
		end

		local peer = self._peer
		if not peer or peer._closed then
			return op.always(nil, 'closed')
		end

		peer._inbuf = peer._inbuf .. data
		local ok, err = flush_complete_lines(peer)
		if not ok then
			return op.always(nil, err)
		end

		return op.always(#data, nil)
	end)
end

function Endpoint:read_line_op()
	return self._line_rx:recv_op():wrap(function(line)
		if line == nil then
			return nil, 'eof'
		end
		return line, nil
	end)
end

function Endpoint:close_op()
	return op.guard(function()
		if self._closed then
			return op.always(true, nil)
		end

		self._closed = true
		self._line_tx:close('closed')

		local peer = self._peer
		if peer and not peer._closed then
			peer._closed = true
			peer._line_tx:close('peer_closed')
		end

		return op.always(true, nil)
	end)
end

function Endpoint:setvbuf(_mode, _size)
	return self
end

-- Synchronous wrappers to mimic fibers.io.stream.Stream.
function Endpoint:write(...)
	return fibers.perform(self:write_op(...))
end

function Endpoint:read_line()
	return fibers.perform(self:read_line_op())
end

function Endpoint:close()
	return fibers.perform(self:close_op())
end

local function new_endpoint()
	local tx, rx = mailbox.new(256, { full = 'reject_newest' })
	return setmetatable({
		_line_tx = tx,
		_line_rx = rx,
		_inbuf   = '',
		_peer    = nil,
		_closed  = false,
	}, Endpoint)
end

function M.new_pair()
	local a = new_endpoint()
	local b = new_endpoint()
	a._peer = b
	b._peer = a
	return a, b
end

return M
