-- fibers/io/poller/select.lua
--
-- luaposix.poll()-based poller backend (no epoll required).
-- Intended to be selected via fibers.io.poller.
--
---@module 'fibers.io.poller.select'

local core = require 'fibers.io.poller.core'

-- Try to load luaposix poll support.
local ok, poll_mod = pcall(require, 'posix.poll')
if not ok or type(poll_mod) ~= 'table' or type(poll_mod.poll) ~= 'function' then
	return {
		is_supported = function () return false end,
	}
end
local errno_mod = require 'posix.errno'

local poll_fn = poll_mod.poll

----------------------------------------------------------------------
-- Backend ops for poller.core
----------------------------------------------------------------------

local function new_backend()
	-- No persistent kernel state required for poll(); everything is
	-- derived from the current waitsets on each poll call.
	return {}
end

--- Build the fds table in the shape expected by posix.poll.poll:
---   fds[fd] = { events = { IN = true, OUT = true } }
local function build_fds(rd_waitset, wr_waitset)
	local fds = {}

	-- Any fd with one or more read waiters gets IN.
	for fd, list in pairs(rd_waitset.buckets) do
		if list and #list > 0 then
			local e = fds[fd]
			if not e then
				e = { events = {} }
				fds[fd] = e
			end
			e.events.IN = true
		end
	end

	-- Any fd with one or more write waiters gets OUT.
	for fd, list in pairs(wr_waitset.buckets) do
		if list and #list > 0 then
			local e = fds[fd]
			if not e then
				e = { events = {} }
				fds[fd] = e
			end
			e.events.OUT = true
		end
	end

	return fds
end

local function poll_backend(_, timeout_ms, rd_waitset, wr_waitset)
	local fds = build_fds(rd_waitset, wr_waitset)

	-- poll() with nfds == 0 is defined and just sleeps for timeout.
	local nready, err, eno = poll_fn(fds, timeout_ms)
	if nready == nil then
		-- Treat EINTR as a benign interruption (e.g. SIGCHLD), same as epoll backend.
		if eno == errno_mod.EINTR then
			return {}
		end
		error(('%s (errno %s)'):format(tostring(err), tostring(eno)))
	end
	if nready == 0 then
		return {}
	end

	local events = {}

	-- luaposix reports readiness in fds[fd].revents with flags
	-- such as IN, OUT, ERR, HUP, NVAL.
	for fd, info in pairs(fds) do
		local re = info.revents
		if re then
			local rd_flag  = re.IN or re.HUP or re.ERR or re.NVAL
			local wr_flag  = re.OUT or re.ERR or re.NVAL
			local err_flag = re.ERR or re.NVAL

			if rd_flag or wr_flag or err_flag then
				events[fd] = {
					rd  = not not rd_flag,
					wr  = not not wr_flag,
					err = not not err_flag,
				}
			end
		end
	end

	return events
end

local ops = {
	new_backend  = new_backend,
	poll         = poll_backend,
	-- on_wait_change: not needed for poll(); state is rebuilt each time.
	is_supported = function () return true end,
}

return core.build_poller(ops)
