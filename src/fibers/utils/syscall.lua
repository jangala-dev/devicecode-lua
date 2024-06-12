---@diagnostic disable: inject-field
-- Copyright Jangala

local p_fcntl = require 'posix.fcntl'
local p_unistd = require 'posix.unistd'
local p_stdio = require 'posix.stdio'
local p_wait = require 'posix.sys.wait'
local p_stat = require 'posix.sys.stat'
local p_signal = require 'posix.signal'
local p_socket = require 'posix.sys.socket'
local p_errno = require 'posix.errno'
local p_time = require 'posix.time'
local bit = rawget(_G, "bit") or require 'bit32'

local M = { ffi = {} } -- used this module format due to large number of exported functions

--detect LuaJIT
M.is_LuaJIT = rawget(_G, "jit") and true or false

local ffi = M.is_LuaJIT and require 'ffi' or require 'cffi'
ffi.tonumber = ffi.tonumber or tonumber
ffi.type = ffi.type or type

local ARCH = ffi.arch

-------------------------------------------------------------------------------
-- Compatibility functions
table.pack = table.pack or function(...) -- luacheck: ignore -- Compatibility fallback
    return { n = select("#", ...), ... }
end


-------------------------------------------------------------------------------
-- Local functions (for efficiency)

local band, bor, bnot, _ = bit.band, bit.bor, bit.bnot, bit.lshift


-------------------------------------------------------------------------------
-- Syscall constants

M.SEEK_CUR = p_unistd.SEEK_CUR
M.SEEK_END = p_unistd.SEEK_END
M.SEEK_SET = p_unistd.SEEK_SET

M.O_ACCMODE = 3
M.O_RDONLY = p_fcntl.O_RDONLY
M.O_WRONLY = p_fcntl.O_WRONLY
M.O_RDWR = p_fcntl.O_RDWR
M.O_CREAT = p_fcntl.O_CREAT
M.O_TRUNC = p_fcntl.O_TRUNC
M.O_APPEND = p_fcntl.O_APPEND
M.O_EXCL = p_fcntl.O_EXCL
M.O_NONBLOCK = p_fcntl.O_NONBLOCK
M.O_LARGEFILE = ffi.abi('32bit') and 32768 or 0

M.F_GETFL = p_fcntl.F_GETFL
M.F_SETFL = p_fcntl.F_SETFL

M.EAGAIN = p_errno.EAGAIN
M.EWOULDBLOCK = p_errno.EWOULDBLOCK
M.EINTR = p_errno.EINTR
M.EINPROGRESS = p_errno.EINPROGRESS
M.ESRCH = p_errno.ESRCH

M.SIGKILL = p_signal.SIGKILL
M.SIGTERM = p_signal.SIGTERM

M.S_IRUSR = p_stat.S_IRUSR
M.S_IWUSR = p_stat.S_IWUSR
M.S_IXUSR = p_stat.S_IXUSR
M.S_IRGRP = p_stat.S_IRGRP
M.S_IWGRP = p_stat.S_IWGRP
M.S_IXGRP = p_stat.S_IXGRP
M.S_IROTH = p_stat.S_IROTH
M.S_IWOTH = p_stat.S_IWOTH
M.S_IXOTH = p_stat.S_IXOTH

M.STDIN_FILENO = p_unistd.STDIN_FILENO
M.STDOUT_FILENO = p_unistd.STDOUT_FILENO
M.STDERR_FILENO = p_unistd.STDERR_FILENO

M.SIGPIPE = p_signal.SIGPIPE
M.SIG_IGN = p_signal.SIG_IGN
M.SIGCHLD = p_signal.SIGCHLD

M.CLOCK_REALTIME = p_time.CLOCK_REALTIME
M.CLOCK_MONOTONIC = p_time.CLOCK_MONOTONIC

M.AF_INET = p_socket.AF_INET
M.AF_INET6 = p_socket.AF_INET6
M.AF_NETLINK = p_socket.AF_NETLINK
M.AF_PACKET = p_socket.AF_PACKET
M.AF_UNIX = p_socket.AF_UNIX
M.AF_UNSPEC = p_socket.AF_UNSPEC
M.SO_ERROR = p_socket.SO_ERROR
M.SOCK_DGRAM = p_socket.SOCK_DGRAM
M.SOCK_RAW = p_socket.SOCK_RAW
M.SOCK_STREAM = p_socket.SOCK_STREAM
M.SOL_SOCKET = p_socket.SOL_SOCKET
M.SOMAXCONN = p_socket.SOMAXCONN

M.WNOHANG = p_wait.WNOHANG

-------------------------------------------------------------------------------
-- Luafied stdlib syscalls

function M.fcntl(fd, ...) return p_fcntl.fcntl(fd, ...) end
function M.open(path, mode, perm) return p_fcntl.open(path, mode, perm) end

function M.strerror(err) return p_errno.errno(err) end

function M.stat(path) return p_stat.stat(path) end
function M.fstat(file, ...) return p_stat.fstat(file, ...) end

function M.signal(signum, handler) return p_signal.signal(signum, handler) end
function M.kill(pid, options) return p_signal.kill(pid, options) end
function M.killpg(pgid, sig) return p_signal.kill(pgid, sig) end

function M.accept(fd) return p_socket.accept(fd) end
function M.bind(file, sockaddr) return p_socket.bind(file, sockaddr) end
function M.connect(fd, addr) return p_socket.connect(fd, addr) end
function M.getpeername(sockfd) return p_socket.getpeername(sockfd) end
function M.getsockname(sockfd) return p_socket.getsockname(sockfd) end
function M.getsockopt(fd, level, name) return p_socket.getsockopt(fd, level, name) end
function M.listen(fd, backlog) return p_socket.listen(fd, backlog or M.SOMAXCONN) end
function M.socket(family, socktype, protocol) return p_socket.socket(family, socktype, protocol) end

function M.fileno(file) return p_stdio.fileno(file) end
function M.rename(from, to) return p_stdio.rename(from, to) end

function M.clock_gettime(id) return p_time.clock_gettime(id) end

function M.access(path, mode) return p_unistd.access(path, mode) end
function M.close(fd) return p_unistd.close(fd) end
function M.dup2(fd1, fd2) return p_unistd.dup2(fd1, fd2) end
function M.exec(path, argt) return p_unistd.exec(path, argt) end
function M.execp(path, argt) return p_unistd.execp(path, argt) end
function M.execve(path, argv, _) return p_unistd.exec(path, argv) end
function M.fork() return p_unistd.fork() end
function M.fsync(fd) return p_unistd.fsync(fd) end
function M.getpgrp() return p_unistd.getpgrp() end
function M.getpid() return p_unistd.getpid() end
function M.isatty(fd) return p_unistd.isatty(fd) end
function M.lseek(file, offset, whence) return p_unistd.lseek(file, offset, whence) end
function M.pipe() return p_unistd.pipe() end
function M.read(fd, count) return p_unistd.read(fd, count) end
function M.setpid(what, id, gid) return p_unistd.setpid(what, id, gid) end
function M.unlink(path) return p_unistd.unlink(path) end
function M.write(fd, buf) return p_unistd.write(fd, buf) end

function M.waitpid(pid, options) return p_wait.wait(pid, options) end

function M.exit(status) return os.exit(status) end

-------------------------------------------------------------------------------
-- Convenience functions

function M.set_nonblock(fd)
	local flags = assert(M.fcntl(fd, M.F_GETFL))
	assert( M.fcntl(fd, M.F_SETFL, bor(flags, M.O_NONBLOCK)))
end

function M.set_block(fd)
	local flags = assert(M.fcntl(fd, M.F_GETFL))
	assert( M.fcntl(fd, M.F_SETFL, band(flags, bnot(M.O_NONBLOCK))))
end

function M.monotime()
    local time = M.clock_gettime(M.CLOCK_MONOTONIC)
    return time.tv_sec + time.tv_nsec/1e9, time.tv_sec, time.tv_nsec
end

function M.realtime()
    local time = M.clock_gettime(M.CLOCK_REALTIME)
    return time.tv_sec + time.tv_nsec/1e9, time.tv_sec, time.tv_nsec
end

function M.floatsleep(t)
    local sec = t - t%1
    local nsec = t%1 * 1e9
    local _, _, _, remaining = p_time.nanosleep({tv_sec=sec, tv_nsec=nsec})
    while remaining do
        p_time.nanosleep(remaining)
    end
end

local function wrap_error(retval)
    if retval >= 0 then
        return retval
    else
        local errno = ffi.errno()
        return nil, M.strerror(errno), errno
    end
end

------------------------------------
-- epoll

if ARCH == "x64" or ARCH == "x86" then
    ffi.cdef[[
        typedef struct epoll_event {
            uint8_t raw[12];  // 4 bytes for events + 8 bytes for data
        } epoll_event;
    ]]
elseif ARCH == "mips" or ARCH == "mipsel" or ARCH == "arm64" then
    ffi.cdef[[
        typedef struct epoll_event {
            uint32_t events;
            uint64_t data;
        } epoll_event;
    ]]
else
    error(ARCH.." architecture not specified")
end

ffi.cdef[[
    int epoll_create(int size);
    int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
    int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);

    int fcntl(int fd, int cmd, ...);
    int close(int fd);
    char *strerror(int errnum);
]]

M.EPOLLIN = 0x00000001
M.EPOLLPRI = 0x00000002
M.EPOLLOUT = 0x00000004
M.EPOLLERR = 0x00000008
M.EPOLLHUP = 0x00000010
M.EPOLLNVAL = 0x00000020
M.EPOLLRDNORM = 0x00000040
M.EPOLLRDBAND = 0x00000080
M.EPOLLWRNORM = 0x00000100
M.EPOLLWRBAND = 0x00000200
M.EPOLLMSG = 0x00000400
M.EPOLLRDHUP = 0x00002000

M.EPOLLEXCLUSIVE =  bit.lshift(1, 28)
M.EPOLLWAKEUP = bit.lshift(1, 29)
M.EPOLLONESHOT = bit.lshift(1, 30)
M.EPOLLET = bit.lshift(1, 31)

local EPOLL_CTL_ADD = 1
local EPOLL_CTL_DEL = 2
local EPOLL_CTL_MOD = 3


-- Adjust helper functions based on the architecture:
local get_event
local set_event
local get_data
local set_data

if ARCH == 'x64' or ARCH == 'x86' then
    get_event = function(ev)
        return ffi.cast("uint32_t*", ev.raw)[0]
    end
    set_event = function(ev, value)
        ffi.cast("uint32_t*", ev.raw)[0] = value
    end
    get_data = function(ev)
        return ffi.cast("uint64_t*", ev.raw + 4)[0]
    end
    set_data = function(ev, value)
        ffi.cast("uint64_t*", ev.raw + 4)[0] = value
    end
elseif ARCH == 'mips' or ARCH == 'arm64' or ARCH == 'mipsel' then
    get_event = function(ev)
        return ev.events
    end
    set_event = function(ev, value)
        ev.events = value
    end
    get_data = function(ev)
        return ev.data
    end
    set_data = function(ev, value)
        ev.data = value
    end
else
    error(ARCH.." architecture not specified")
end

-- Returns an epoll file descriptor.
function M.epoll_create()
    return wrap_error(ffi.C.epoll_create(1))
end

-- Register eventmask of a file descriptor onto epoll file descriptor.
function M.epoll_register(epfd, fd, eventmask)
    local event = ffi.new("struct epoll_event")
    set_event(event, eventmask)
    set_data(event, fd)
    return wrap_error(ffi.C.epoll_ctl(epfd, EPOLL_CTL_ADD, fd, event))
end

-- Modify eventmask of a file descriptor.
function M.epoll_modify(epfd, fd, eventmask)
    local event = ffi.new("struct epoll_event")
    set_event(event, eventmask)
    set_data(event, fd)
    return wrap_error(ffi.C.epoll_ctl(epfd, EPOLL_CTL_MOD, fd, event))
end

-- Remove a registered file descriptor from the epoll file descriptor.
function M.epoll_unregister(epfd, fd)
    return wrap_error(ffi.C.epoll_ctl(epfd, EPOLL_CTL_DEL, fd, nil))
end

-- Wait for events.
function M.epoll_wait(epfd, timeout, max_events)
    local events = ffi.new("struct epoll_event[?]", max_events)
    local num_events = ffi.C.epoll_wait(epfd, events, max_events, timeout)
    if num_events == -1 then
        return nil, ffi.string(ffi.C.strerror(ffi.errno()))
    end

    -- Create a table to hold the resulting events
    local res = {}

    -- Loop over the events, inserting them into the table with their fd as the key
    for i = 0, num_events - 1 do
        local fd = assert(ffi.tonumber(get_data(events[i])))
        local event = assert(ffi.tonumber(get_event(events[i])))
        res[fd] = event
    end

    return res, num_events
end

-- Close epoll file descriptor.
function M.epoll_close(epfd)
    return wrap_error(ffi.C.close(epfd))
end


-------------------------------------------------------------------------------
-- FFI C structure functions (for efficiency)

M.ffi.typeof = ffi.typeof
M.ffi.sizeof = ffi.sizeof

ffi.cdef [[
    ssize_t write(int fildes, const void *buf, size_t nbytes);
    ssize_t read(int fildes, void *buf, size_t nbytes);
    int memcmp(const void *s1, const void *s2, size_t n);
]]

function M.ffi.write(fildes, buf, nbytes)
    return wrap_error(ffi.tonumber(ffi.C.write(fildes, buf, nbytes)))
end

function M.ffi.read(fildes, buf, nbytes)
    return wrap_error(ffi.tonumber(ffi.C.read(fildes, buf, nbytes)))
end

function M.ffi.memcmp(obj1, obj2, nbytes)
    return ffi.tonumber(ffi.C.memcmp(obj1, obj2, nbytes))
end

-- Explicitly load the pthread library

local pthread_names = {
    "pthread",
    "libpthread.so.0"
}

local libpthread = nil

for _, v in ipairs(pthread_names) do
    local success
    success, libpthread = pcall(ffi.load, v)
    if success then break end
end

if not libpthread then error("libpthread not found") end

ffi.cdef[[
typedef struct {
    uint32_t ssi_signo;    /* Signal number */
    int32_t  ssi_errno;    /* Error number (unused) */
    int32_t  ssi_code;     /* Signal code */
    uint32_t ssi_pid;      /* PID of sender */
    uint32_t ssi_uid;      /* Real UID of sender */
    int32_t  ssi_fd;       /* File descriptor (SIGIO) */
    uint32_t ssi_tid;      /* Kernel timer ID (POSIX timers) */
    uint32_t ssi_band;     /* Band event (SIGIO) */
    uint32_t ssi_overrun;  /* POSIX timer overrun count */
    uint32_t ssi_trapno;   /* Trap number that caused signal */
    int32_t  ssi_status;   /* Exit status or signal (SIGCHLD) */
    int32_t  ssi_int;      /* Integer sent by sigqueue(3) */
    uint64_t ssi_ptr;      /* Pointer sent by sigqueue(3) */
    uint64_t ssi_utime;    /* User CPU time consumed (SIGCHLD) */
    uint64_t ssi_stime;    /* System CPU time consumed (SIGCHLD) */
    uint64_t ssi_addr;     /* Address that generated signal (for hardware-generated signals) */
    uint16_t ssi_addr_lsb; /* Least significant bit of address (SIGBUS; since Linux 2.6.37) */
    uint16_t __pad2;
    int32_t  ssi_syscall;
    uint64_t ssi_call_addr;
    uint32_t ssi_arch;
    uint8_t  pad[28];      /* Pad size to 128 bytes */
} signalfd_siginfo;

typedef struct {
    unsigned long int __val[1024 / (8 * sizeof (unsigned long int))];
} __sigset_t;

typedef __sigset_t sigset_t;

int pthread_sigmask(int how, const sigset_t *set, sigset_t *oldset);
int sigemptyset(sigset_t *set);
int sigaddset(sigset_t *set, int signum);
int signalfd(int fd, const sigset_t *mask, int flags);
]]

if ARCH == "mips" or ARCH == "mipsel" then
    M.SIG_BLOCK = 1
    M.SIG_UNBLOCK = 2
    M.SIG_SETMASK = 3
elseif ARCH == "x64" or ARCH == "arm64" or ARCH == "x86" then
    M.SIG_BLOCK = 0
    M.SIG_UNBLOCK = 1
    M.SIG_SETMASK = 2
end

function M.sigemptyset(set) return wrap_error(ffi.C.sigemptyset(set)) end
function M.sigaddset(set, signum) return wrap_error(ffi.C.sigaddset(set, signum)) end
function M.signalfd(fd, mask, flags) return wrap_error(ffi.C.signalfd(fd, mask, flags)) end

function M.pthread_sigmask(how, set, oldset) return wrap_error(libpthread.pthread_sigmask(how, set, oldset)) end

function M.new_sigset() return ffi.new("sigset_t") end
function M.new_fdsi() return ffi.new("signalfd_siginfo"), ffi.sizeof("signalfd_siginfo") end

-- Define syscall and pid_t
ffi.cdef[[
long syscall(long number, ...);
typedef int pid_t;
typedef unsigned int uint;
]]

local SYS_pidfd_open = 434 -- Good for (almost) all our platforms
if ARCH == "mips" or ARCH == "mipsel" then
    SYS_pidfd_open = 4000 + 434 -- See https://www.linux-mips.org/wiki/Syscall
end

-- Function to open a pidfd
function M.pidfd_open(pid, flags)
    pid = ffi.new("pid_t", pid)  -- Explicitly cast pid to pid_t
    flags = ffi.new("uint", flags)  -- Explicitly cast flgas to uint
    return wrap_error(ffi.tonumber(ffi.C.syscall(SYS_pidfd_open, pid, flags)))
end

return M
