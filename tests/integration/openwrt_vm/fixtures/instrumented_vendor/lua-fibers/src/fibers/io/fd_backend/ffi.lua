-- fibers/io/fd_backend/ffi.lua
--
-- FFI-based FD backend (no luaposix / syscall dependency).
-- Intended to be selected via fibers.io.fd_backend.
--
---@module 'fibers.io.fd_backend.ffi'

local core  = require 'fibers.io.fd_backend.core'
local ffi_c = require 'fibers.utils.ffi_compat'

if not ffi_c.is_supported() then
	return { is_supported = function () return false end }
end

local ffi       = ffi_c.ffi
local C         = ffi_c.C
local toint     = ffi_c.tonumber
local get_errno = ffi_c.errno

local ok_bit, bit_mod = pcall(function ()
	return rawget(_G, 'bit') or require 'bit32'
end)
if not ok_bit or not bit_mod then
	return { is_supported = function () return false end }
end
local bit = bit_mod

---@class sockaddr_un_cdata
---@field sun_family integer
---@field sun_path string|integer[]

ffi.cdef [[
  typedef long ssize_t;
  typedef long off_t;

  ssize_t read(int fd, void *buf, size_t count);
  ssize_t write(int fd, const void *buf, size_t count);
  off_t   lseek(int fd, off_t offset, int whence);
  int     close(int fd);
  int     fcntl(int fd, int cmd, ...);
  char   *strerror(int errnum);

  int     open(const char *pathname, int flags, int mode);
  int     pipe(int pipefd[2]);
  int     fsync(int fd);
  int     rename(const char *oldpath, const char *newpath);
  int     unlink(const char *pathname);
  int     mkdir(const char *pathname, int mode);

  typedef void (*sighandler_t)(int);
  sighandler_t signal(int signum, sighandler_t handler);

  /* socket API */
  typedef unsigned short sa_family_t;
  typedef unsigned int   socklen_t;

  struct sockaddr {
    sa_family_t sa_family;
    char        sa_data[14];
  };

  struct sockaddr_un {
    sa_family_t sun_family;
    char        sun_path[108];
  };

  int socket(int domain, int type, int protocol);
  int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int listen(int sockfd, int backlog);
  int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
  int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
  int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen);

  typedef unsigned short in_port_t;
  typedef unsigned int   in_addr_t;

  struct in_addr {
    in_addr_t s_addr;
  };

  struct sockaddr_in {
    sa_family_t    sin_family;
    in_port_t      sin_port;
    struct in_addr sin_addr;
    unsigned char  sin_zero[8];
  };

  unsigned short htons(unsigned short hostshort);
  int inet_pton(int af, const char *src, void *dst);
]]

-- POSIX fcntl command numbers on Linux.
local F_GETFL = 3
local F_SETFL = 4

-- Linux O_* constants (values as on glibc/Linux; adjust if you support other ABIs).
local O_RDONLY   = 0x0000
local O_WRONLY   = 0x0001
local O_RDWR     = 0x0002
local O_ACCMODE  = 0x0003
local O_CREAT    = 0x0040
local O_EXCL     = 0x0080
local O_TRUNC    = 0x0200
local O_APPEND   = 0x0400
local O_NONBLOCK = 0x00000800

-- Permission bits (standard POSIX values).
local S_IRUSR = 0x0100
local S_IWUSR = 0x0080
local S_IRGRP = 0x0020
local S_IROTH = 0x0004
local S_IWGRP = 0x0010
local S_IWOTH = 0x0002
local S_IXUSR = 0x0040
local S_IXGRP = 0x0008
local S_IXOTH = 0x0001

-- Errno values (Linux).
local EAGAIN      = 11
local EWOULDBLOCK = 11
local EINPROGRESS = 115

-- Socket constants (Linux ABI).
local AF_UNIX     = 1
local AF_INET     = 2
local SOCK_STREAM = 1
local SOL_SOCKET  = 1
local SO_ERROR    = 4
local SOMAXCONN   = 128

local SIGPIPE = 13

local function strerror(e)
	local s = C.strerror(e)
	if s == nil then
		return 'errno ' .. tostring(e)
	end
	return ffi.string(s)
end

----------------------------------------------------------------------
-- fcntl helpers (casted to avoid varargs issues)
----------------------------------------------------------------------

local getfl_fp = ffi.cast('int (*)(int, int)', C.fcntl)
local setfl_fp = ffi.cast('int (*)(int, int, int)', C.fcntl)

local function set_nonblock(fd)
	local before = assert(toint(getfl_fp(fd, F_GETFL)))
	if before < 0 then
		local e = get_errno()
		return false, ('F_GETFL failed: %s'):format(strerror(e)), e
	end

	local new_flags = bit.bor(before, O_NONBLOCK)
	local rc        = toint(setfl_fp(fd, F_SETFL, new_flags))
	if rc < 0 then
		local e = get_errno()
		return false, ('F_SETFL failed: %s'):format(strerror(e)), e
	end

	-- Optional sanity check.
	local after = assert(toint(getfl_fp(fd, F_GETFL)))
	if after < 0 then
		local e = get_errno()
		return false, ('F_GETFL (post) failed: %s'):format(strerror(e)), e
	end

	if bit.band(after, O_NONBLOCK) == 0 then
		return false,
			('set_nonblock: O_NONBLOCK not set after F_SETFL; before=0x%x after=0x%x')
			:format(before, after),
			nil
	end

	return true, nil, nil
end

----------------------------------------------------------------------
-- Low-level ops implementing the core contract
----------------------------------------------------------------------

local SEEK = { set = 0, cur = 1, ['end'] = 2 }

local function read_fd(fd, max)
	local buf = ffi.new('char[?]', max)
	local n   = toint(C.read(fd, buf, max))

	if n < 0 then
		local e = get_errno()
		if e == EAGAIN or e == EWOULDBLOCK then
			return nil, nil, 'rd' -- would block
		end
		return nil, strerror(e)
	end

	if n == 0 then
		return '', nil -- EOF
	end

	if n > max then
		return nil, 'read returned ' .. tostring(n) .. ' bytes (max ' .. tostring(max) .. ')'
	end

	return ffi.string(buf, n), nil
end

local function write_fd(fd, str, len)
	local buf = ffi.new('char[?]', len)
	ffi.copy(buf, str, len)

	local n = toint(C.write(fd, buf, len))
	if n < 0 then
		local e = get_errno()
		if e == EAGAIN or e == EWOULDBLOCK then
			return nil, nil, 'wr' -- would block
		end
		return nil, strerror(e)
	end

	return n, nil
end

local function seek_fd(fd, whence, off)
	local w = SEEK[whence]
	if not w then
		return nil, 'bad whence: ' .. tostring(whence)
	end

	local res = toint(C.lseek(fd, off, w))
	if res < 0 then
		return nil, strerror(get_errno())
	end

	return res, nil
end

local function close_fd(fd)
	local rc = toint(C.close(fd))
	if rc ~= 0 then
		return false, strerror(get_errno())
	end
	return true, nil
end

----------------------------------------------------------------------
-- File-level helpers
----------------------------------------------------------------------

local function open_fd(path, flags, perms)
	local c_path = ffi.new('char[?]', #path + 1)
	ffi.copy(c_path, path)
	local fd = toint(C.open(c_path, flags, perms or 0))
	if fd < 0 then
		local e = get_errno()
		return nil, strerror(e)
	end
	return fd, nil
end

local function pipe_fd()
	local fds = ffi.new('int[2]')
	local rc  = toint(C.pipe(fds))
	if rc ~= 0 then
		local e = get_errno()
		return nil, nil, strerror(e)
	end
	return toint(fds[0]), toint(fds[1]), nil
end

local function fsync_fd(fd)
	local rc = toint(C.fsync(fd))
	if rc ~= 0 then
		local e = get_errno()
		return false, strerror(e)
	end
	return true, nil
end

local function rename_file(oldpath, newpath)
	local c_old = ffi.new('char[?]', #oldpath + 1)
	ffi.copy(c_old, oldpath)
	local c_new = ffi.new('char[?]', #newpath + 1)
	ffi.copy(c_new, newpath)

	local rc = toint(C.rename(c_old, c_new))
	if rc ~= 0 then
		local e = get_errno()
		return false, strerror(e)
	end
	return true, nil
end

local function unlink_file(path)
	local c_path = ffi.new('char[?]', #path + 1)
	ffi.copy(c_path, path)

	local rc = toint(C.unlink(c_path))
	if rc ~= 0 then
		local e = get_errno()
		return false, strerror(e)
	end
	return true, nil
end

-- Mode and permission tables mirror the old file.lua behaviour,
-- but live in the backend.

---@type table<string, integer>
local modes = {
	r      = O_RDONLY,
	w      = bit.bor(O_WRONLY, O_CREAT, O_TRUNC),
	a      = bit.bor(O_WRONLY, O_CREAT, O_APPEND),
	['r+'] = O_RDWR,
	['w+'] = bit.bor(O_RDWR, O_CREAT, O_TRUNC),
	['a+'] = bit.bor(O_RDWR, O_CREAT, O_APPEND),
}

do
	local binary_modes = {}
	for k, v in pairs(modes) do
		binary_modes[k .. 'b'] = v
	end
	for k, v in pairs(binary_modes) do
		modes[k] = v
	end
end

---@type table<string, integer>
local permissions = {}
permissions['rw-r--r--'] = bit.bor(S_IRUSR, S_IWUSR, S_IRGRP, S_IROTH)
permissions['rw-rw-rw-'] = bit.bor(permissions['rw-r--r--'], S_IWGRP, S_IWOTH)
permissions['rwxr-xr-x'] = bit.bor(
	S_IRUSR, S_IWUSR, S_IXUSR,
	S_IRGRP, S_IXGRP,
	S_IROTH, S_IXOTH
)
permissions['rwx------'] = bit.bor(S_IRUSR, S_IWUSR, S_IXUSR)

local function mkdir_path(path, perms)
	-- Normalise perms: nil -> sensible default for dirs, string -> lookup, number -> passthrough.
	local p
	if perms == nil then
		p = permissions['rwxr-xr-x']
	elseif type(perms) == 'string' then
		p = permissions[perms] or perms
	else
		p = perms
	end

	local c_path = ffi.new('char[?]', #path + 1)
	ffi.copy(c_path, path)

	local rc = toint(C.mkdir(c_path, p))
	if rc ~= 0 then
		local e = get_errno()
		return false, strerror(e)
	end
	return true, nil
end

local function open_file(path, mode, perms)
	mode = mode or 'r'
	local flags = modes[mode]
	if not flags then
		return nil, 'invalid mode: ' .. tostring(mode)
	end

	local p
	if perms == nil then
		p = permissions['rw-rw-rw-']
	elseif type(perms) == 'string' then
		p = permissions[perms] or perms
	else
		p = perms
	end

	return open_fd(path, flags, p)
end

local function mktemp(prefix, perms)
	-- Normalise perms: nil -> default, string -> lookup in permissions table.
	if perms == nil then
		perms = permissions['rw-r--r--']
	elseif type(perms) == 'string' then
		perms = permissions[perms] or perms
	end

	-- Caller is responsible for seeding math.random appropriately.
	local start = math.random(1e7)
	local tmpnam, fd, err

	for i = start, start + 10 do
		tmpnam = prefix .. '.' .. i
		fd, err = open_fd(tmpnam, bit.bor(O_CREAT, O_RDWR, O_EXCL), perms)
		if fd then
			return fd, tmpnam
		end
	end

	return nil, ('failed to create temporary file %s: %s'):format(
		tostring(tmpnam),
		tostring(err)
	)
end

local function decode_access(flags)
	local acc = bit.band(flags, O_ACCMODE)
	if acc == O_RDONLY then
		return true, false
	elseif acc == O_WRONLY then
		return false, true
	elseif acc == O_RDWR then
		return true, true
	end
	-- Fallback: if we cannot interpret, assume read/write.
	return true, true
end

local function ignore_sigpipe()
	-- Best-effort ignore of SIGPIPE. If this fails, we treat it as non-fatal.
	local handler_t = ffi.typeof('sighandler_t')
	local SIG_IGN   = ffi.cast(handler_t, 1)

	local old = C.signal(SIGPIPE, SIG_IGN)
	if old == nil then
		local e = get_errno()
		return false, strerror(e)
	end
	return true, nil
end

----------------------------------------------------------------------
-- Socket helpers (AF_UNIX, SOCK_STREAM, path string sockaddr)
----------------------------------------------------------------------

local function make_sockaddr_un(path)
	local sa = ffi.new('struct sockaddr_un')
	---@cast sa sockaddr_un_cdata
	sa.sun_family = AF_UNIX

	local maxlen = 108 - 1
	local p = path
	if #p > maxlen then
		p = p:sub(1, maxlen)
	end
	ffi.fill(sa.sun_path, 108)
	ffi.copy(sa.sun_path, p)

	-- Full struct size is fine for bind/connect.
	local len = ffi.sizeof('struct sockaddr_un')
	return sa, len
end

local function make_sockaddr_in(host, port)
	if type(host) ~= 'string' or host == '' then
		return nil, nil, 'host must be a non-empty string'
	end

	port = tonumber(port)
	if not port or port < 0 or port > 65535 then
		return nil, nil, 'port must be 0..65535'
	end

	local sa      = ffi.new('struct sockaddr_in')
	sa.sin_family = AF_INET
	sa.sin_port   = C.htons(tonumber(port))

	local c_host = ffi.new('char[?]', #host + 1)
	ffi.copy(c_host, host)

	local addr = ffi.new('struct in_addr[1]')
	local rc = toint(C.inet_pton(AF_INET, c_host, addr))
	if rc ~= 1 then
		if rc == 0 then
			return nil, nil, 'invalid IPv4 address: ' .. tostring(host)
		end
		local e = get_errno()
		return nil, nil, strerror(e)
	end

	sa.sin_addr = addr[0]
	ffi.fill(sa.sin_zero, 8)

	return sa, ffi.sizeof('struct sockaddr_in'), nil
end

local function socket_fd(domain, stype, protocol)
	local fd = toint(C.socket(domain, stype, protocol or 0))
	if fd < 0 then
		local e = get_errno()
		return nil, strerror(e), e
	end
	return fd, nil, nil
end

local function bind_fd(fd, sa)
	local c_sa, len, serr

	if type(sa) == 'string' then
		-- AF_UNIX path
		c_sa, len = make_sockaddr_un(sa)
	elseif type(sa) == 'table' and sa.family == 'inet' then
		-- AF_INET token: { family = 'inet', host = '1.2.3.4', port = 1234 }
		c_sa, len, serr = make_sockaddr_in(sa.host, sa.port)
		if not c_sa then
			return false, serr, nil
		end
	else
		return false, 'unsupported sockaddr representation', nil
	end

	local rc = toint(C.bind(fd, ffi.cast('struct sockaddr *', c_sa), len))
	if rc ~= 0 then
		local e = get_errno()
		return false, strerror(e), e
	end
	return true, nil, nil
end

local function listen_fd(fd)
	local rc = toint(C.listen(fd, SOMAXCONN))
	if rc ~= 0 then
		local e = get_errno()
		return false, strerror(e), e
	end
	return true, nil, nil
end

--- accept(fd) -> newfd|nil, err|nil, again:boolean
local function accept_fd(fd)
	local new_fd = toint(C.accept(fd, nil, nil))
	if new_fd < 0 then
		local e = get_errno()
		if e == EAGAIN or e == EWOULDBLOCK then
			return nil, nil, true
		end
		return nil, strerror(e), false
	end
	return new_fd, nil, false
end

--- connect_start(fd, sa) -> ok|nil, err|nil, inprogress:boolean
local function connect_start_fd(fd, sa)
	local c_sa, len, serr

	if type(sa) == 'string' then
		-- AF_UNIX path
		c_sa, len = make_sockaddr_un(sa)
	elseif type(sa) == 'table' and sa.family == 'inet' then
		-- AF_INET token
		c_sa, len, serr = make_sockaddr_in(sa.host, sa.port)
		if not c_sa then
			return nil, serr, false
		end
	else
		return nil, 'unsupported sockaddr representation', false
	end

	local rc = toint(C.connect(fd, ffi.cast('struct sockaddr *', c_sa), len))
	if rc == 0 then
		return true, nil, false
	end

	local e = get_errno()
	if e == EINPROGRESS then
		return nil, nil, true
	end
	return nil, strerror(e), false
end

--- connect_finish(fd) -> ok:boolean, err|nil
local function connect_finish_fd(fd)
	local errval = ffi.new('int[1]')
	local sz     = ffi.new('socklen_t[1]', ffi.sizeof('int'))
	local rc     = toint(C.getsockopt(fd, SOL_SOCKET, SO_ERROR, errval, sz))
	if rc ~= 0 then
		local e = get_errno()
		return false, strerror(e)
	end
	local soerr = errval[0]
	if soerr == 0 then
		return true, nil
	end
	return false, strerror(soerr)
end

----------------------------------------------------------------------
-- Capability probe
----------------------------------------------------------------------

local function is_supported()
	return true
end

local ops = {
	set_nonblock = set_nonblock,
	read         = read_fd,
	write        = write_fd,
	seek         = seek_fd,
	close        = close_fd,

	mkdir          = mkdir_path,
	open_file      = open_file,
	pipe           = pipe_fd,
	mktemp         = mktemp,
	fsync          = fsync_fd,
	rename         = rename_file,
	unlink         = unlink_file,
	decode_access  = decode_access,
	ignore_sigpipe = ignore_sigpipe,

	-- socket ops
	socket         = socket_fd,
	bind           = bind_fd,
	listen         = listen_fd,
	accept         = accept_fd,
	connect_start  = connect_start_fd,
	connect_finish = connect_finish_fd,

	modes       = modes,
	permissions = permissions,

	AF_UNIX     = AF_UNIX,
	AF_INET     = AF_INET,
	SOCK_STREAM = SOCK_STREAM,

	is_supported = is_supported,
}

return core.build_backend(ops)
