-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

-- Epoll.

local sc = require 'fibers.utils.syscall'
local bit = rawget(_G, "bit") or require 'bit32'

local Epoll = {}

local INITIAL_MAXEVENTS = 8

local function new()
    local ret = {
        epfd = assert(sc.epoll_create()),
        active_events = {},
        maxevents = INITIAL_MAXEVENTS,
    }
    return setmetatable(ret, { __index = Epoll })
end

local RD = sc.EPOLLIN + sc.EPOLLRDHUP
local WR = sc.EPOLLOUT
local RDWR = RD + WR
local ERR = sc.EPOLLERR + sc.EPOLLHUP
local PRI = sc.EPOLLPRI

function Epoll:add(s, events)
    -- local fd = type(s) == 'number' and s or sc.fileno(s)
    local fd = s
    local active = self.active_events[fd] or 0
    local eventmask = bit.bor(events, active, sc.EPOLLONESHOT)
    local ok, _ = sc.epoll_modify(self.epfd, fd, eventmask)
    if not ok then assert(sc.epoll_register(self.epfd, fd, eventmask)) end
end

function Epoll:poll(timeout)
    -- Returns a table, an iterator would be more efficient.
    -- print("self.epfd", self.epfd)
    -- print("self.maxevents", self.maxevents)
    local events, err = sc.epoll_wait(self.epfd, timeout or 0, self.maxevents)
    if not events then
        error(err)
    end
    local count = 0
    -- Since we add fd's with EPOLL_ONESHOT, now that the event has
    -- fired, the fd is now deactivated.  Record that fact.
    for fd, _ in pairs(events) do
        count = count + 1
        self.active_events[fd] = nil
    end
    if count == self.maxevents then
        -- If we received `maxevents' events, it means that probably there
        -- are more active fd's in the queue that we were unable to
        -- receive.  Expand our event buffer in that case.
        self.maxevents = self.maxevents * 2
    end
    return events, err
end

function Epoll:close()
    sc.epoll_close(self.epfd)
    self.epfd = nil
end

return {
    new = new,
    RD = RD,
    WR = WR,
    RDWR = RDWR,
    ERR = ERR,
    PRI = PRI,
}
