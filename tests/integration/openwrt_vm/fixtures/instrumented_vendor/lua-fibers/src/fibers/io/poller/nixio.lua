-- fibers/io/poller/nixio.lua
--
-- nixio.poll()-based poller backend (no epoll / luaposix dependency).
-- Intended to be selected via fibers.io.poller.
--
---@module 'fibers.io.poller.nixio'

local core  = require 'fibers.io.poller.core'
local nixio = require 'nixio'

----------------------------------------------------------------------
-- Backend ops for poller.core
----------------------------------------------------------------------

local function new_backend()
	-- No persistent kernel state required; everything is derived from the
	-- current waitsets on each poll call.
	return {}
end

--- Build the fds table in the shape expected by nixio.poll:
---   fds[i] = { fd = <File|Socket>, events = <bitfield> }
---
--- Here the "fd" field is the nixio object itself; poll() accepts that.
local function build_fds(rd_waitset, wr_waitset)
	local fds = {}
	local index = 1

	-- We need to iterate over the union of keys in both waitsets.
	local seen = {}

	for fd, list in pairs(rd_waitset.buckets) do
		if list and #list > 0 then
			local events = nixio.poll_flags('in')
			fds[index] = { fd = fd, events = events }
			seen[fd] = index
			index = index + 1
		end
	end

	for fd, list in pairs(wr_waitset.buckets) do
		if list and #list > 0 then
			local pos = seen[fd]
			if pos then
				local e = fds[pos]
				e.events = nixio.poll_flags(e.events, 'out')
			else
				local events = nixio.poll_flags('out')
				fds[index] = { fd = fd, events = events }
				seen[fd] = index
				index = index + 1
			end
		end
	end

	return fds
end

local function poll_backend(_, timeout_ms, rd_waitset, wr_waitset)
	local fds = build_fds(rd_waitset, wr_waitset)

	-- nixio.poll(fds, timeout_ms) -> nready, fds'
	local nready, fds_ret, _, _ = nixio.poll(fds, timeout_ms)

	if not nready then
		-- Treat EINTR as benign; anything else can reasonably surface.
		-- For a "simple" backend you can choose to treat all errors as
		-- "no events"; if you prefer you can error() here instead.
		return {}
	end

	if nready == 0 then
		return {}
	end

	local events = {}

	for _, info in pairs(fds_ret) do
		local revents = info.revents or 0
		if revents ~= 0 then
			local flags = nixio.poll_flags(revents)
			events[info.fd] = {
				rd  = not not (flags['in'] or flags.hup or flags.err or flags.nval),
				wr  = not not (flags.out or flags.err or flags.nval),
				err = not not (flags.err or flags.nval),
			}
		end
	end

	return events
end

local function is_supported()
	local ok = pcall(require, 'nixio')
	return ok
end

local ops = {
	new_backend  = new_backend,
	poll         = poll_backend,
	-- on_wait_change not needed; state is rebuilt each poll.
	is_supported = is_supported,
}

return core.build_poller(ops)
