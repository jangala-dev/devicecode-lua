-- fibers/io/fd_backend/posix.lua
--
-- luaposix-based FD backend (no FFI).
-- Intended to be selected via fibers.io.fd_backend.
--
---@module 'fibers.io.fd_backend.posix'

local core = require 'fibers.io.fd_backend.core'

local unistd     = require 'posix.unistd'
local stdio      = require 'posix.stdio'
local fcntl      = require 'posix.fcntl'
local pstat      = require 'posix.sys.stat'
local errno      = require 'posix.errno'
local psig       = require 'posix.signal'
local socket_mod = require 'posix.sys.socket'

local bit = rawget(_G, 'bit') or require 'bit32'

local function errno_msg(prefix, err, eno)
	if err and err ~= '' then
		return err
	end
	if eno then
		return ('%s (errno %d)'):format(prefix, eno)
	end
	return prefix
end

----------------------------------------------------------------------
-- set_nonblock / basic ops
----------------------------------------------------------------------

local function set_nonblock(fd)
	local flags, err, eno = fcntl.fcntl(fd, fcntl.F_GETFL)
	if flags == nil then
		return false, errno_msg('fcntl(F_GETFL)', err, eno), eno
	end
	local newflags = bit.bor(flags, fcntl.O_NONBLOCK)
	local ok, err2, eno2 = fcntl.fcntl(fd, fcntl.F_SETFL, newflags)
	if ok == nil then
		return false, errno_msg('fcntl(F_SETFL)', err2, eno2), eno2
	end
	return true, nil, nil
end

local function read_fd(fd, max)
	local s, err, eno = unistd.read(fd, max)
	if s == nil then
		if eno == errno.EAGAIN or eno == errno.EWOULDBLOCK then
			return nil, nil, 'rd'
		end
		return nil, errno_msg('read failed', err, eno)
	end
	return s, nil
end

local function write_fd(fd, str, _)
	local n, err, eno = unistd.write(fd, str)
	if n == nil then
		if eno == errno.EAGAIN or eno == errno.EWOULDBLOCK then
			return nil, nil, 'wr'
		end
		return nil, errno_msg('write failed', err, eno)
	end
	return n, nil
end

local SEEK = { set = unistd.SEEK_SET, cur = unistd.SEEK_CUR, ['end'] = unistd.SEEK_END }

local function seek_fd(fd, whence, off)
	local w = SEEK[whence]
	if not w then
		return nil, 'bad whence: ' .. tostring(whence)
	end
	local pos, err, eno = unistd.lseek(fd, off, w)
	if pos == nil then
		return nil, errno_msg('lseek failed', err, eno)
	end
	return pos, nil
end

local function close_fd(fd)
	local ok, err, eno = unistd.close(fd)
	if ok == nil then
		return false, errno_msg('close failed', err, eno)
	end
	return true, nil
end

----------------------------------------------------------------------
-- File-level helpers
----------------------------------------------------------------------

local modes = {
	r      = fcntl.O_RDONLY,
	w      = bit.bor(fcntl.O_WRONLY, fcntl.O_CREAT, fcntl.O_TRUNC),
	a      = bit.bor(fcntl.O_WRONLY, fcntl.O_CREAT, fcntl.O_APPEND),
	['r+'] = fcntl.O_RDWR,
	['w+'] = bit.bor(fcntl.O_RDWR, fcntl.O_CREAT, fcntl.O_TRUNC),
	['a+'] = bit.bor(fcntl.O_RDWR, fcntl.O_CREAT, fcntl.O_APPEND),
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

local permissions = {}
permissions['rw-r--r--'] = bit.bor(pstat.S_IRUSR, pstat.S_IWUSR, pstat.S_IRGRP, pstat.S_IROTH)
permissions['rw-rw-rw-'] = bit.bor(permissions['rw-r--r--'], pstat.S_IWGRP, pstat.S_IWOTH)

permissions['rwxr-xr-x'] = bit.bor(
	pstat.S_IRUSR, pstat.S_IWUSR, pstat.S_IXUSR,
	pstat.S_IRGRP,              pstat.S_IXGRP,
	pstat.S_IROTH,              pstat.S_IXOTH
)
permissions['rwx------'] = bit.bor(pstat.S_IRUSR, pstat.S_IWUSR, pstat.S_IXUSR)

local function mkdir_path(path, perms)
	local p
	if perms == nil then
		p = permissions['rwxr-xr-x']
	elseif type(perms) == 'string' then
		p = permissions[perms] or perms
	else
		p = perms
	end

	local ok, err, eno = pstat.mkdir(path, p)
	if ok == nil then
		return false, errno_msg('mkdir failed', err, eno)
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

	local fd, err, eno = fcntl.open(path, flags, p)
	if not fd then
		return nil, errno_msg('open failed', err, eno)
	end
	return fd, nil
end

local function pipe_fds()
	local rd, wr, err, eno = unistd.pipe()
	if not rd then
		return nil, nil, errno_msg('pipe failed', err, eno)
	end
	return rd, wr, nil
end

local function mktemp(prefix, perms)
	if perms == nil then
		perms = permissions['rw-r--r--']
	elseif type(perms) == 'string' then
		perms = permissions[perms] or perms
	end

	local start = math.random(1e7)
	local tmpnam, fd, err, eno

	for i = start, start + 10 do
		tmpnam = prefix .. '.' .. i
		fd, err, eno = fcntl.open(
			tmpnam,
			bit.bor(fcntl.O_CREAT, fcntl.O_RDWR, fcntl.O_EXCL),
			perms
		)
		if fd then
			return fd, tmpnam
		end
	end

	return nil, ('failed to create temporary file %s: %s'):format(
		tostring(tmpnam),
		tostring(errno_msg('open', err, eno))
	)
end

local function fsync_fd(fd)
	local ok, err, eno = unistd.fsync(fd)
	if ok == nil then
		return false, errno_msg('fsync failed', err, eno)
	end
	return true, nil
end

local function rename_file(oldpath, newpath)
	local ok, err, eno = stdio.rename(oldpath, newpath)
	if ok == nil then
		return false, errno_msg('rename failed', err, eno)
	end
	return true, nil
end

local function unlink_file(path)
	local ok, err, eno = unistd.unlink(path)
	if ok == nil then
		return false, errno_msg('unlink failed', err, eno)
	end
	return true, nil
end

local function decode_access(flags)
	local o_wr   = fcntl.O_WRONLY or 0
	local o_rdwr = fcntl.O_RDWR or 0
	local readable
	if o_wr ~= 0 then
		readable = (bit.band(flags, o_wr) ~= o_wr)
	else
		readable = true
	end

	local writable = false
	if o_wr ~= 0 and bit.band(flags, o_wr) ~= 0 then
		writable = true
	end
	if o_rdwr ~= 0 and bit.band(flags, o_rdwr) ~= 0 then
		writable = true
	end

	if not readable and not writable then
		readable = true
	end

	return readable, writable
end

local function ignore_sigpipe()
	local ok, err, eno = psig.signal(psig.SIGPIPE, psig.SIG_IGN)
	if ok == nil then
		return false, errno_msg('signal(SIGPIPE)', err, eno)
	end
	return true, nil
end

----------------------------------------------------------------------
-- Socket helpers on top of posix.sys.socket
----------------------------------------------------------------------

local AF_UNIX     = socket_mod.AF_UNIX
local AF_INET     = socket_mod.AF_INET
local AF_INET6    = socket_mod.AF_INET6
local SOCK_STREAM = socket_mod.SOCK_STREAM
local SOCK_DGRAM  = socket_mod.SOCK_DGRAM

-- Normalise sockaddr tokens used by higher layers into luaposix sockaddr tables.
-- Accepted inputs:
--   UNIX:
--     "/tmp/sock"
--     { family = "unix", path = "/tmp/sock" }
--   INET:
--     { family = "inet",  host = "127.0.0.1", port = 1234 }
--     { family = "inet",  addr = "127.0.0.1", port = 1234 }
--   INET6:
--     { family = "inet6", host = "::1",       port = 1234 }
--   Raw luaposix sockaddr table:
--     { family = socket_mod.AF_INET, addr = "...", port = ... }
local function norm_sockaddr(sa)
	if type(sa) == 'string' then
		-- Convenience form: UNIX path
		return { family = AF_UNIX, path = sa }
	end

	if type(sa) ~= 'table' then
		return nil, 'unsupported sockaddr representation'
	end

	-- If this already looks like a luaposix sockaddr table, accept it.
	if type(sa.family) == 'number' then
		return sa
	end

	local fam = sa.family or sa.af
	if fam == 'unix' then
		if not AF_UNIX then
			return nil, 'AF_UNIX not supported'
		end
		local path = sa.path or sa.host
		if type(path) ~= 'string' or path == '' then
			return nil, 'invalid unix sockaddr path'
		end
		return { family = AF_UNIX, path = path }
	end

	if fam == 'inet' then
		if not AF_INET then
			return nil, 'AF_INET not supported'
		end
		local addr = sa.addr or sa.host
		local port = tonumber(sa.port)
		if addr ~= nil and type(addr) ~= 'string' then
			return nil, 'invalid inet sockaddr addr'
		end
		if port == nil then
			return nil, 'invalid inet sockaddr port'
		end
		return { family = AF_INET, addr = addr, port = port }
	end

	if fam == 'inet6' then
		if not AF_INET6 then
			return nil, 'AF_INET6 not supported'
		end
		local addr = sa.addr or sa.host
		local port = tonumber(sa.port)
		if addr ~= nil and type(addr) ~= 'string' then
			return nil, 'invalid inet6 sockaddr addr'
		end
		if port == nil then
			return nil, 'invalid inet6 sockaddr port'
		end
		return { family = AF_INET6, addr = addr, port = port }
	end

	return nil, 'unsupported sockaddr family'
end

--- Create a socket fd.
---@param domain integer
---@param stype integer
---@param protocol? integer
---@return integer|nil fd, string|nil err, integer|nil eno
local function socket_fd(domain, stype, protocol)
	local fd, err, eno = socket_mod.socket(domain, stype, protocol or 0)
	if fd == nil then
		return nil, errno_msg('socket failed', err, eno), eno
	end
	return fd, nil, nil
end

--- Bind a socket to an address token.
---@param fd integer
---@param sa any
---@return boolean ok, string|nil err, integer|nil eno
local function bind_fd(fd, sa)
	local addr, aerr = norm_sockaddr(sa)
	if not addr then
		return false, aerr, nil
	end

	local ok, err, eno = socket_mod.bind(fd, addr)
	if ok == nil then
		return false, errno_msg('bind failed', err, eno), eno
	end
	return true, nil, nil
end

--- Put a listening socket into listen state.
---@param fd integer
---@return boolean ok, string|nil err, integer|nil eno
local function listen_fd(fd)
	local backlog = socket_mod.SOMAXCONN or 128
	local ok, err, eno = socket_mod.listen(fd, backlog)
	if ok == nil then
		return false, errno_msg('listen failed', err, eno), eno
	end
	return true, nil, nil
end

--- accept(fd) -> newfd|nil, err|nil, again:boolean
---@param fd integer
---@return integer|nil newfd, string|nil err, boolean again
local function accept_fd(fd)
	local newfd, addr_or_err, errnum = socket_mod.accept(fd)
	if newfd ~= nil then
		return newfd, nil, false
	end

	local eno = errnum
	if eno == errno.EAGAIN or eno == errno.EWOULDBLOCK then
		return nil, nil, true
	end

	return nil, errno_msg('accept failed', addr_or_err, eno), false
end

--- Start a non-blocking connect.
--- connect_start(fd, sa) -> ok|nil, err|nil, inprogress:boolean
---@param fd integer
---@param sa any
---@return boolean|nil ok, string|nil err, boolean inprogress
local function connect_start_fd(fd, sa)
	local addr, aerr = norm_sockaddr(sa)
	if not addr then
		return nil, aerr, false
	end

	local ok, err, eno = socket_mod.connect(fd, addr)
	if ok ~= nil then
		return true, nil, false
	end

	if eno == errno.EINPROGRESS or eno == errno.EALREADY or eno == errno.EAGAIN then
		return nil, nil, true
	end

	return nil, errno_msg('connect failed', err, eno), false
end

--- Complete a non-blocking connect using SO_ERROR.
---@param fd integer
---@return boolean ok, string|nil err
local function connect_finish_fd(fd)
	local soerr, err, eno = socket_mod.getsockopt(
		fd, socket_mod.SOL_SOCKET, socket_mod.SO_ERROR
	)
	if soerr == nil then
		return false, errno_msg('getsockopt(SO_ERROR) failed', err, eno)
	end

	soerr = tonumber(soerr) or 0
	if soerr == 0 then
		return true, nil
	end

	return false, 'connect error errno ' .. tostring(soerr)
end

local function is_supported()
	return true
end

----------------------------------------------------------------------
-- Assemble ops and build backend
----------------------------------------------------------------------

local ops = {
	set_nonblock = set_nonblock,
	read         = read_fd,
	write        = write_fd,
	seek         = seek_fd,
	close        = close_fd,

	open_file      = open_file,
	pipe           = pipe_fds,
	mktemp         = mktemp,
	fsync          = fsync_fd,
	rename         = rename_file,
	unlink         = unlink_file,
	mkdir          = mkdir_path,
	decode_access  = decode_access,
	ignore_sigpipe = ignore_sigpipe,

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
	AF_INET6    = AF_INET6,
	SOCK_STREAM = SOCK_STREAM,
	SOCK_DGRAM  = SOCK_DGRAM,

	is_supported = is_supported,
}

return core.build_backend(ops)
