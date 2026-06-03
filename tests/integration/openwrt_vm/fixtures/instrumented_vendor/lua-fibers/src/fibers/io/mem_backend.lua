-- fibers/io/mem_backend.lua
--
-- In-memory duplex pair (pipe-like) backend.
--
-- Backend contract towards fibers.io.stream:
--   * kind()              -> "mem"
--   * fileno()            -> nil
--   * read_string(max)    -> str|nil, err|nil
--        - str == nil  : would block
--        - str == ""   : EOF
--   * write_string(str)   -> n|nil, err|nil
--        - n == nil    : would block
--   * on_readable(task)   -> token{ unlink = fn }
--   * on_writable(task)   -> token{ unlink = fn }
--   * close()             -> ok, err|nil

local runtime = require 'fibers.runtime'
local wait    = require 'fibers.wait'
local bytes   = require 'fibers.utils.bytes'

local RingBuf = bytes.RingBuf

local function new_half(bufsize)
	local H = {
		rx        = RingBuf.new(bufsize or 4096),
		r_wait    = wait.new_waitset(),
		w_wait    = wait.new_waitset(),
		peer      = nil,
		rx_closed = false, -- peer has closed its write side
		closed    = false, -- this half has been closed
	}

	local function schedule_all(waitset, key)
		local sched = runtime.current_scheduler
		waitset:notify_all(key, sched)
	end

	function H:kind()
		return 'mem'
	end

	function H:fileno()
		return nil
	end

	--------------------------------------------------------------------
	-- String-oriented I/O, for use by fibers.io.stream
	--------------------------------------------------------------------

	-- Read up to max bytes as a Lua string.
	--   * returns "" when peer has closed and no more data → EOF.
	--   * returns nil, nil when no data and not closed yet → would block.
	function H:read_string(max)
		local have = self.rx:read_avail()
		if have == 0 then
			if self.rx_closed then
				-- EOF
				return '', nil
			end
			-- Would block
			return nil, nil
		end

		local n = math.min(have, max or have)
		local chunk = self.rx:take(n)

		-- Space freed → wake peer writers.
		local peer = self.peer
		if peer then
			schedule_all(peer.w_wait, peer)
		end

		return chunk, nil
	end

	-- Write a Lua string into the peer's receive buffer.
	--   * returns nil, "closed" if peer is gone.
	--   * returns nil, nil when no space → would block.
	function H:write_string(str)
		local peer = self.peer
		if not peer or peer.rx_closed then
			return nil, 'closed'
		end

		local len = #str
		if len == 0 then
			return 0, nil
		end

		local room = peer.rx:write_avail()
		if room == 0 then
			if peer.rx_closed then
				return nil, 'closed'
			end
			-- Would block.
			return nil, nil
		end

		local n = math.min(room, len)
		peer.rx:put(str:sub(1, n))

		-- Data available → wake peer readers.
		schedule_all(peer.r_wait, peer)

		return n, nil
	end

	--------------------------------------------------------------------
	-- Readiness registration
	--------------------------------------------------------------------

	function H:on_readable(task)
		-- Key by this half; effectively one bucket.
		return self.r_wait:add(self, task)
	end

	function H:on_writable(task)
		return self.w_wait:add(self, task)
	end

	--------------------------------------------------------------------
	-- Lifecycle
	--------------------------------------------------------------------

	function H:close()
		if self.closed then
			return true
		end
		self.closed = true

		local peer = self.peer
		self.peer = nil

		-- Wake any local waiters so they can observe closure.
		schedule_all(self.r_wait, self)
		schedule_all(self.w_wait, self)

		if peer then
			-- Indicate EOF to the peer's read side and wake its waiters.
			peer.rx_closed = true
			schedule_all(peer.r_wait, peer)
			schedule_all(peer.w_wait, peer)
			peer.peer = nil
		end

		return true
	end

	return H
end

local function pipe(bufsize)
	local a, b = new_half(bufsize), new_half(bufsize)
	a.peer, b.peer = b, a
	return a, b
end

return { pipe = pipe }
