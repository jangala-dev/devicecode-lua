-- fibers.channel
-- Concurrent ML style channels for communication between fibers.
---@module 'fibers.channel'

local op      = require 'fibers.op'
local fifo    = require 'fibers.utils.fifo'
local dlist   = require 'fibers.utils.dlist'
local perform = require 'fibers.performer'.perform

--- Bidirectional communication channel between fibers.
---@class Channel
---@field buffer table|nil     # optional FIFO buffer (nil for unbuffered)
---@field buffer_size integer
---@field getq table           # cancellable wait-list of waiting receivers
---@field putq table           # cancellable wait-list of waiting senders
local Channel = {}
Channel.__index = Channel

--- Create a new channel.
---@param buffer_size? integer # buffered capacity (0 or nil for unbuffered)
---@return Channel
local function new(buffer_size)
	buffer_size = buffer_size or 0

	local buffer = nil
	if buffer_size > 0 then
		buffer = fifo.new()
	end

	return setmetatable({
		buffer      = buffer,
		buffer_size = buffer_size,
		getq        = dlist.new(), -- waiting receivers
		putq        = dlist.new(), -- waiting senders
	}, Channel)
end

----------------------------------------------------------------------
-- Helpers: cancellable wait-list entries
----------------------------------------------------------------------

--- Pop the next entry whose suspension is still waiting, if any.
---@param q any
---@return table|nil
local function pop_active(q)
	while not q:empty() do
		local entry = q:pop_head()
		if not entry.suspension or entry.suspension:waiting() then
			return entry
		end
	end
	return nil
end

---@param entry table
local function cleanup_get_entry(entry)
	entry.suspension = nil
	entry.wrap = nil
end

---@param entry table
local function cleanup_put_entry(entry)
	entry.val = nil
	entry.suspension = nil
	entry.wrap = nil
end

--- Op that sends val on the channel.
--- For unbuffered channels, this synchronises with a receiver; for buffered
--- channels, it may complete when space is available in the buffer.
---@param val any
---@return Op
function Channel:put_op(val)
	local getq, putq = self.getq, self.putq
	local buffer, buffer_size = self.buffer, self.buffer_size

	local function try()
		-- Case 1: rendezvous with a waiting receiver.
		local recv = pop_active(getq)
		if recv then
			recv.suspension:complete(recv.wrap, val)
			cleanup_get_entry(recv)
			return true
		end
		-- Case 2: buffered channel with available space.
		if buffer and buffer:length() < buffer_size then
			buffer:push(val)
			return true
		end
		-- Case 3: no receiver and no buffer space.
		return false
	end

	--- Enqueue as a waiting sender when the put cannot complete immediately.
	---@param suspension Suspension
	---@param wrap_fn WrapFn
	local function block(suspension, wrap_fn)
		---@class ChannelPutEntry
		---@field val any
		---@field suspension Suspension|nil
		---@field wrap WrapFn|nil
		local entry = {
			val        = val,
			suspension = suspension,
			wrap       = wrap_fn,
		}
		local node = putq:push_tail(entry)
		suspension:add_cleanup(function ()
			if node:remove() then
				cleanup_put_entry(entry)
			end
		end)
	end

	return op.new_primitive(nil, try, block)
end

--- Op that receives a value from the channel.
--- May take from the buffer or rendezvous directly with a sender.
---@return Op
function Channel:get_op()
	local getq, putq = self.getq, self.putq
	local buffer     = self.buffer

	local function pop_sender()
		local sender = pop_active(putq)
		if not sender then
			return nil
		end
		-- Having chosen this sender, complete its suspension immediately.
		sender.suspension:complete(sender.wrap)
		return sender
	end

	local function try()
		local remote = pop_sender()
		-- Case 1: take from buffer if there is a buffered value.
		if buffer and buffer:length() > 0 then
			local v = buffer:pop()
			-- If there was a sender waiting, refill the buffer with its value.
			if remote then
				buffer:push(remote.val)
				cleanup_put_entry(remote)
			end
			return true, v
		end
		-- Case 2: no buffered value; take directly from a sender.
		if remote then
			local v = remote.val
			cleanup_put_entry(remote)
			return true, v
		end
		-- Case 3: nothing available.
		return false
	end

	--- Enqueue as a waiting receiver when no value is immediately available.
	---@param suspension Suspension
	---@param wrap_fn WrapFn
	local function block(suspension, wrap_fn)
		---@class ChannelGetEntry
		---@field suspension Suspension|nil
		---@field wrap WrapFn|nil
		local entry = {
			suspension = suspension,
			wrap       = wrap_fn,
		}
		local node = getq:push_tail(entry)
		suspension:add_cleanup(function ()
			if node:remove() then
				cleanup_get_entry(entry)
			end
		end)
	end

	return op.new_primitive(nil, try, block)
end

--- Synchronously send message on the channel.
---@param message any
function Channel:put(message)
	return perform(self:put_op(message))
end

--- Synchronously receive a message from the channel.
---@return any
function Channel:get()
	return perform(self:get_op())
end

return {
	new = new,
}
