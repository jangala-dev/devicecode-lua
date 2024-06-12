-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- fibers.stream.file module
-- A stream IO implementation for file descriptors.
-- @module fibers.stream.file

package.path = "../../?.lua;../?.lua;" .. package.path

local stream = require 'fibers.stream'
local sc = require 'fibers.utils.syscall'

local bit = rawget(_G, "bit") or require 'bit32'

-- A blocking handler provides for configurable handling of EWOULDBLOCK
-- conditions.  The goal is to allow for normal blocking operations, but
-- also to allow for a cooperative coroutine-based multitasking system
-- to run other tasks when a stream would block.
--
-- In the case of normal, blocking file descriptors, the blocking
-- handler will only be called if a read or a write returns EAGAIN,
-- presumably because the sc was interrupted by a signal.  In that
-- case the correct behavior is to just return directly, which will
-- cause the stream to try again.
--
-- For nonblocking file descriptors, the blocking handler could suspend
-- the current coroutine and arrange to restart it once the FD becomes
-- readable or writable.  However the default handler here doesn't
-- assume that we're running in a coroutine.  In that case we could
-- block in a poll() without suspending.  Currently however the default
-- blocking handler just returns directly, which will cause the stream
-- to busy-wait until the FD becomes active.

local blocking_handler

local default_blocking_handler = {}
function default_blocking_handler:init_nonblocking() end

function default_blocking_handler:wait_for_readable() end

function default_blocking_handler:wait_for_writable() end

function default_blocking_handler:wait_for_priority() end

local function set_blocking_handler(h)
    blocking_handler = h or default_blocking_handler
end

set_blocking_handler()

local function init_nonblocking(fd) blocking_handler:init_nonblocking(fd) end
local function wait_for_readable(fd) blocking_handler:wait_for_readable(fd) end
local function wait_for_writable(fd) blocking_handler:wait_for_writable(fd) end
local function wait_for_priority(fd) blocking_handler:wait_for_priority(fd) end

local File = {}
local File_mt = { __index = File }

local function new_file_io(fd, filename)
    init_nonblocking(fd)
    return setmetatable({ fd = fd, filename = filename }, File_mt)
end

function File:nonblock() sc.set_nonblock(self.fd) end

function File:block() sc.set_block(self.fd) end

function File:read(buf, count)
    local did_read, err, errno = sc.ffi.read(self.fd, buf, count)
    if errno then
        -- If the read would block, indicate to caller with nil return.
        if errno == sc.EAGAIN or errno == sc.EWOULDBLOCK then return nil end
        -- Otherwise, signal an error.
        error(err)
    else
        -- Success; return number of bytes read.  If EOF, count is 0.
        return did_read
    end
end

function File:write(buf, count)
    local did_write, err, errno = sc.ffi.write(self.fd, buf, count)
    if err then
        -- If the write would block, indicate to caller with nil return.
        if errno == sc.EAGAIN or errno == sc.EWOULDBLOCK then return nil end
        -- Otherwise, signal an error.
        error(err)
    elseif did_write == 0 then
        -- This is a bit of a squirrely case: no bytes written, but no
        -- error code.  Return nil to indicate that it's probably a good
        -- idea to wait until the FD is writable again.
        return nil
    else
        -- Success; return number of bytes written.
        return did_write
    end
end

function File:seek(whence, offset)
    -- In case of success, return the final file position, measured in
    -- bytes from the beginning of the file.  On failure, return nil,
    -- plus a string describing the error.
    return sc.lseek(self.fd, offset, whence)
end

function File:wait_for_readable() wait_for_readable(self.fd) end

function File:wait_for_writable() wait_for_writable(self.fd) end

function File:wait_for_priority() wait_for_priority(self.fd) end

function File:close()
    sc.close(self.fd)
    self.fd = nil
end

local function fdopen(fd, flags, filename)
    local io = new_file_io(fd, filename)
    if flags == nil then
        flags = assert(sc.fcntl(fd, sc.F_GETFL))
        -- this appears only to be relevant to 32 bit systems, ljsc has
        -- reference to this being a flag with value octal('0100000') on such systems
    else
        flags = bit.bor(flags, sc.O_LARGEFILE)
    end
    local readable, writable = false, false
    local mode = bit.band(flags, sc.O_ACCMODE)
    if mode == sc.O_RDONLY or mode == sc.O_RDWR then readable = true end
    if mode == sc.O_WRONLY or mode == sc.O_RDWR then writable = true end
    local stat = sc.fstat(fd)
    return stream.open(io, readable, writable, stat and stat.st_blksize)
end

local modes = {
    r = sc.O_RDONLY,
    w = bit.bor(sc.O_WRONLY, sc.O_CREAT, sc.O_TRUNC),
    a = bit.bor(sc.O_WRONLY, sc.O_CREAT, sc.O_APPEND),
    ['r+'] = sc.O_RDWR,
    ['w+'] = bit.bor(sc.O_RDWR, sc.O_CREAT, sc.O_TRUNC),
    ['a+'] = bit.bor(sc.O_RDWR, sc.O_CREAT, sc.O_APPEND)
}
do
    local binary_modes = {}
    for k, v in pairs(modes) do binary_modes[k .. 'b'] = v end
    for k, v in pairs(binary_modes) do modes[k] = v end
end

local permissions = {}
permissions['rw-r--r--'] = bit.bor(sc.S_IRUSR, sc.S_IWUSR, sc.S_IRGRP, sc.S_IROTH)
permissions['rw-rw-rw-'] = bit.bor(permissions['rw-r--r--'], sc.S_IWGRP, sc.S_IWOTH)

local function open(filename, mode, perms)
    if mode == nil then mode = 'r' end
    local flags = modes[mode]
    if flags == nil then return nil, 'invalid mode: ' .. tostring(mode) end
    -- This set of permissions is what open() uses.  Note that these
    -- permissions will be modulated by the umask.
    if perms == nil then perms = permissions['rw-rw-rw-'] end
    local fd, err, _ = sc.open(filename, flags, permissions[perms])
    if fd == nil then return nil, err end
    return fdopen(fd, flags, filename)
end

local function mktemp(name, perms)
    if perms == nil then perms = permissions['rw-r--r--'] end
    -- In practice this requires that someone seeds math.random with good
    -- entropy.  In Snabb that is the case (see core.main:initialize()).
    local t = math.random(1e7)
    local tmpnam, fd, err, _
    for i = t, t + 10 do
        tmpnam = name .. '.' .. i
        fd, err, _ = sc.open(tmpnam, bit.bor(sc.O_CREAT, sc.O_RDWR, sc.O_EXCL), perms)
        if fd then return fd, tmpnam end
    end
    error("Failed to create temporary file " .. tmpnam .. ": " .. err)
end

local function tmpfile(perms, tmpdir)
    if tmpdir == nil then tmpdir = os.getenv("TMPDIR") or "/tmp" end
    local fd, tmpnam = mktemp(tmpdir .. '/' .. 'tmp', perms)
    local f = fdopen(fd, sc.O_RDWR, tmpnam)
    -- FIXME: Doesn't arrange to ensure the file is removed in all cases;
    -- calling close is required.
    function f:rename(new)
        self:flush()
        sc.fsync(self.io.fd)
        local res, err = sc.rename(self.io.filename, new)
        if not res then
            error("failed to rename " .. self.io.filename .. " to " .. new .. ": " .. tostring(err))
        end
        self.io.filename = new
        self.io.close = File.close -- Disable remove-on-close.
    end

    function f.io:close()
        File.close(self)
        local res, err = sc.unlink(self.filename)
        if not res then
            error('failed to remove ' .. self.filename .. ': ' .. tostring(err))
        end
    end

    return f
end

local function pipe()
    local rd, wr = assert(sc.pipe())
    return fdopen(rd, sc.O_RDONLY), fdopen(wr, sc.O_WRONLY)
end

local function popen(prog, mode)
    assert(type(prog) == 'string')
    assert(mode == 'r' or mode == 'w')
    local parent_half, child_half
    do
        local rd, wr = assert(sc.pipe())
        if mode == 'r' then
            parent_half, child_half = rd, wr
        else
            parent_half, child_half = wr, rd
        end
    end
    local pid = assert(sc.fork())
    if pid == 0 then
        sc.close(parent_half)
        sc.dup2(child_half, mode == 'r' and 1 or 0)
        sc.close(child_half)
        sc.execve('/bin/sh', { "-c", prog })
        sc.write(2, "io.popen: Failed to exec /bin/sh!")
        sc.exit(255)
    end
    sc.close(child_half)
    local io = new_file_io(parent_half)
    local close = io.close
    function io:close()
        if not pid then return end
        close(self)
        local ch_pid, status, code
        repeat
            ch_pid, status, code = sc.waitpid(pid, sc.WNOHANG)
            -- some kind of sleep here, surely, if used in a fibers context
        until (ch_pid and status ~= 'running') or (not ch_pid and code ~= sc.EINTR)
        pid = nil
        local retval1 = (status == "exited" and code == 0) or nil
        local retval2 = status == "exited" and "exit" or "signal"
        local retval3 = code
        return retval1, retval2, retval3
    end

    return stream.open(io, mode == 'r', mode == 'w')
end

return {
    init_nonblocking = init_nonblocking,
    wait_for_readable = wait_for_readable,
    wait_for_writable = wait_for_writable,
    wait_for_priority = wait_for_priority,
    set_blocking_handler = set_blocking_handler,
    fdopen = fdopen,
    open = open,
    tmpfile = tmpfile,
    pipe = pipe,
    popen = popen,
}
