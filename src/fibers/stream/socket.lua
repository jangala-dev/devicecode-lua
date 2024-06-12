-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- A stream IO implementation for sockets.

local file = require 'fibers.stream.file'
local sc = require 'fibers.utils.syscall'

local Socket = {}
Socket.__index = Socket

local sigpipe_handler

local function socket(domain, stype, protocol)
    if sigpipe_handler == nil then sigpipe_handler = sc.signal(sc.SIGPIPE, sc.SIG_IGN) end
    local fd = assert(sc.socket(domain, stype, protocol or 0))
    file.init_nonblocking(fd)
    return setmetatable({ fd = fd }, Socket)
end

function Socket:listen_unix(f)
    local sa = sc.getsockname(self.fd)
    sa.path = f
    assert(sc.bind(self.fd, sa))
    assert(sc.listen(self.fd))
end

function Socket:accept()
    while true do
        local fd, err, errno = sc.accept(self.fd)
        if fd then
            return file.fdopen(fd)
        elseif errno == sc.EAGAIN or errno == sc.EWOULDBLOCK then
            file.wait_for_readable(self.fd)
        else
            error(err)
        end
    end
end

function Socket:connect(sa)
    local ok, err, errno = sc.connect(self.fd, sa)
    if not ok and errno == sc.EINPROGRESS then
        -- Bonkers semantics; see connect(2).
        file.wait_for_writable(self.fd)
        err = assert(sc.getsockopt(self.fd, sc.SOL_SOCKET, sc.SO_ERROR))
        if err == 0 then ok = true end
    end
    if ok then
        local fd = self.fd
        self.fd = nil
        return file.fdopen(fd)
    end
    error(err)
end

function Socket:connect_unix(f)
    local sa = sc.getsockname(self.fd)
    sa.path = f
    return self:connect(sa)
end

local function listen_unix(f, args)
    args = args or {}
    local s = socket(sc.AF_UNIX, args.stype or sc.SOCK_STREAM, args.protocol)
    s:listen_unix(f)
    if args.ephemeral then
        local parent_close = s.close
        function s:close()
            parent_close(s)
            sc.unlink(f)
        end
    end
    return s
end

local function connect_unix(f, stype, protocol)
    local s = socket(sc.AF_UNIX, stype or sc.SOCK_STREAM, protocol)
    return s:connect_unix(f)
end

function Socket:close()
    if self.fd then sc.close(self.fd) end
    self.fd = nil
end

return {
    socket = socket,
    listen_unix = listen_unix,
    connect_unix = connect_unix
}
