-- fibers/io/poller/epoll.lua
--
-- Linux epoll-based poller backend.
-- Supports LuaJIT (ffi) and PUC Lua with cffi via ffi_compat.
-- Intended to be selected via fibers.io.poller.
--
---@module 'fibers.io.poller.epoll'

local core  = require 'fibers.io.poller.core'
local safe  = require 'coxpcall'
local bit   = rawget(_G, 'bit') or require 'bit32'
local ffi_c = require 'fibers.utils.ffi_compat'

----------------------------------------------------------------------
-- FFI / CFFI setup via ffi_compat
----------------------------------------------------------------------

if not (ffi_c.is_supported and ffi_c.is_supported()) then
	return { is_supported = function () return false end }
end

local ffi          = ffi_c.ffi
local C            = ffi_c.C
local ffi_tonumber = ffi_c.tonumber
local get_errno    = ffi_c.errno

local EPERM  = 1
local EINTR  = 4
local ENOENT = 2
local EBADF  = 9

local jit = rawget(_G, 'jit')
local ARCH = ffi.arch or ((jit and jit.arch) or 'x64')

----------------------------------------------------------------------
-- Low-level epoll bindings
----------------------------------------------------------------------

ffi.cdef [[
  typedef unsigned char      uint8_t;
  typedef unsigned int       uint32_t;
  typedef unsigned long long uint64_t;

  int epoll_create(int size);
  int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
  int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);

  int close(int fd);
  char *strerror(int errnum);
]]

-- epoll_event layout differs by architecture.
if ARCH == 'x64' or ARCH == 'x86' then
	ffi.cdef [[
    typedef struct epoll_event {
      uint8_t raw[12];  // 4 bytes for events + 8 bytes for data
    } epoll_event;
  ]]
elseif ARCH == 'mips' or ARCH == 'mipsel' or ARCH == 'arm64' then
	ffi.cdef [[
    typedef struct epoll_event {
      uint32_t events;
      uint64_t data;
    } epoll_event;
  ]]
else
	error('fibers.io.poller.epoll: unsupported architecture ' .. tostring(ARCH))
end

-- Event bits.
local EPOLLIN      = 0x00000001
local EPOLLOUT     = 0x00000004
local EPOLLERR     = 0x00000008
local EPOLLHUP     = 0x00000010
local EPOLLRDHUP   = 0x00002000
local EPOLLONESHOT = bit.lshift(1, 30)

local EPOLL_CTL_ADD = 1
local EPOLL_CTL_DEL = 2
local EPOLL_CTL_MOD = 3

-- Architecture-dependent field access.
local get_event, set_event, get_data, set_data

if ARCH == 'x64' or ARCH == 'x86' then
	get_event = function (ev) return ffi.cast('uint32_t*', ev.raw)[0] end
	set_event = function (ev, value) ffi.cast('uint32_t*', ev.raw)[0] = value end
	get_data  = function (ev) return ffi.cast('uint64_t*', ev.raw + 4)[0] end
	set_data  = function (ev, value) ffi.cast('uint64_t*', ev.raw + 4)[0] = value end
else
	get_event = function (ev) return ev.events end
	set_event = function (ev, value) ev.events = value end
	get_data  = function (ev) return ev.data end
	set_data  = function (ev, value) ev.data = value end
end

local function wrap_error(ret)
	if ret == -1 then
		local errno = get_errno()
		local err   = ffi.string(C.strerror(errno))
		return nil, err, errno
	end
	return ret, nil, nil
end

local function epoll_create()
	local fd, err, errno = wrap_error(C.epoll_create(1))
	if not fd then
		error(err or ('epoll_create failed (errno ' .. tostring(errno) .. ')'))
	end
	return fd
end

local function epoll_ctl_add(epfd, fd, mask)
	local ev = ffi.new('struct epoll_event')
	set_event(ev, mask)
	set_data(ev, fd)
	return wrap_error(C.epoll_ctl(epfd, EPOLL_CTL_ADD, fd, ev))
end

local function epoll_ctl_mod(epfd, fd, mask)
	local ev = ffi.new('struct epoll_event')
	set_event(ev, mask)
	set_data(ev, fd)
	return wrap_error(C.epoll_ctl(epfd, EPOLL_CTL_MOD, fd, ev))
end

local function epoll_ctl_del(epfd, fd)
	return wrap_error(C.epoll_ctl(epfd, EPOLL_CTL_DEL, fd, nil))
end

local function epoll_wait(epfd, timeout_ms, max_events)
	local events = ffi.new('struct epoll_event[?]', max_events)
	local n      = C.epoll_wait(epfd, events, max_events, timeout_ms or 0)
	if n == -1 then
		local errno = get_errno()
		if errno == EINTR then
			return {}, nil, errno
		end
		local err = ffi.string(C.strerror(errno))
		return nil, err, errno
	end

	local res = {}
	for i = 0, n - 1 do
		local fd    = assert(ffi_tonumber(get_data(events[i])))
		local event = assert(ffi_tonumber(get_event(events[i])))
		res[fd]     = event
	end
	return res, nil, nil
end

local function epoll_close(epfd)
	return wrap_error(C.close(epfd))
end

----------------------------------------------------------------------
-- Epoll wrapper object
----------------------------------------------------------------------

---@class EpollState
---@field epfd integer
---@field active_events table<integer, integer>
---@field unpollable table<integer, boolean>   -- fds that return EPERM to epoll_ctl
---@field maxevents integer
local Epoll = {}
Epoll.__index = Epoll

local INITIAL_MAXEVENTS = 8

local function new_epoll()
	local ret = {
		epfd          = epoll_create(),
		active_events = {},
		unpollable    = {},
		maxevents     = INITIAL_MAXEVENTS,
	}
	return setmetatable(ret, Epoll)
end

local RD  = EPOLLIN + EPOLLRDHUP
local WR  = EPOLLOUT
local ERR = EPOLLERR + EPOLLHUP

local function die_ctl(opname, fd, err, errno)
	error((opname .. ' failed for fd ' .. tostring(fd) .. ' (' .. tostring(err) .. ', errno ' .. tostring(errno) .. ')'))
end

function Epoll:add(fd, events)
	-- Once an fd is known to be unpollable, do not try to epoll_ctl it again.
	if self.unpollable[fd] then
		return
	end

	local active    = self.active_events[fd] or 0
	local eventmask = bit.bor(events, active, EPOLLONESHOT)

	-- Try MOD first (common case).
	local ok, err, eno = epoll_ctl_mod(self.epfd, fd, eventmask)
	if ok then
		self.active_events[fd] = eventmask
		return
	end

	-- EPERM: fd type not supported by epoll (e.g. regular file). Treat as unpollable.
	if eno == EPERM then
		self.active_events[fd] = nil
		self.unpollable[fd]    = true
		return
	end

	-- Not currently registered (or MOD failed): try ADD.
	local ok2, err2, eno2 = epoll_ctl_add(self.epfd, fd, eventmask)
	if ok2 then
		self.active_events[fd] = eventmask
		return
	end

	if eno2 == EPERM then
		self.active_events[fd] = nil
		self.unpollable[fd]    = true
		return
	end

	die_ctl('epoll_ctl(ADD)', fd, err2 or err, eno2 or eno)
end

function Epoll:poll(timeout_ms)
	local evmap, err, errno = epoll_wait(self.epfd, timeout_ms or 0, self.maxevents)
	if not evmap then
		error(err or ('epoll_wait failed (errno ' .. tostring(errno) .. ')'))
	end

	local count = 0
	for fd, _ in pairs(evmap) do
		count = count + 1
		self.active_events[fd] = nil
	end
	if count == self.maxevents then
		self.maxevents = self.maxevents * 2
	end

	return evmap
end

function Epoll:del(fd)
	-- If this fd was unpollable, there is no kernel state to delete.
	if self.unpollable[fd] then
		self.unpollable[fd] = nil
		self.active_events[fd] = nil
		return
	end

	local ok, err, errno = epoll_ctl_del(self.epfd, fd)
	if not ok then
		if errno == ENOENT or errno == EBADF then
			self.active_events[fd] = nil
			return
		end
		die_ctl('epoll_ctl(DEL)', fd, err, errno)
	end

	self.active_events[fd] = nil
end

function Epoll:close()
	epoll_close(self.epfd)
	self.epfd = nil
	self.active_events = {}
	self.unpollable = {}
end

----------------------------------------------------------------------
-- Backend ops for poller.core
----------------------------------------------------------------------

local function new_backend()
	return new_epoll()
end

local function on_wait_change(ep, fd, want_rd, want_wr)
	local mask = 0
	if want_rd then mask = bit.bor(mask, RD) end
	if want_wr then mask = bit.bor(mask, WR) end

	if mask ~= 0 then
		ep:add(fd, mask)
	else
		ep:del(fd)
	end
end

local function poll_backend(ep, timeout_ms, rd_waitset, wr_waitset)
	local events = {}

	-- Synthesize readiness for fds that epoll cannot watch (EPERM).
	-- This keeps Poller:wait and backend registration exception-free.
	local had_synthetic = false
	if ep.unpollable then
		for fd, _ in pairs(ep.unpollable) do
			local rd = rd_waitset and (not rd_waitset:is_empty(fd)) or false
			local wr = wr_waitset and (not wr_waitset:is_empty(fd)) or false
			if rd or wr then
				had_synthetic = true
				events[fd] = { rd = rd, wr = wr, err = false }
			end
		end
	end

	-- If we have synthetic events to deliver, do not block in epoll_wait.
	local real_timeout = had_synthetic and 0 or timeout_ms

	local evmap = ep:poll(real_timeout)
	for fd, ev in pairs(evmap) do
		local flags = {
			rd  = bit.band(ev, RD + ERR) ~= 0,
			wr  = bit.band(ev, WR + ERR) ~= 0,
			err = bit.band(ev, ERR) ~= 0,
		}
		local cur = events[fd]
		if cur then
			-- Merge with any synthetic readiness.
			cur.rd  = cur.rd or flags.rd
			cur.wr  = cur.wr or flags.wr
			cur.err = cur.err or flags.err
		else
			events[fd] = flags
		end
	end

	return events
end

local function close_backend(ep)
	ep:close()
end

local function is_supported()
	local ok = safe.pcall(function ()
		local e = new_epoll()
		e:close()
	end)
	return ok
end

local ops = {
	new_backend    = new_backend,
	on_wait_change = on_wait_change,
	poll           = poll_backend,
	close_backend  = close_backend,
	is_supported   = is_supported,
}

return core.build_poller(ops)
