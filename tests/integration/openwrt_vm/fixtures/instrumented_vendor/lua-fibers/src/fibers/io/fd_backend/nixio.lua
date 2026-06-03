-- fibers/io/fd_backend/nixio.lua
--
-- nixio-based FD backend (no FFI / luaposix dependency).
-- Intended to be selected via fibers.io.fd_backend.
--
---@module 'fibers.io.fd_backend.nixio'

local core  = require 'fibers.io.fd_backend.core'
local nixio = require 'nixio'
local fs    = require 'nixio.fs'

local const = nixio.const or {}

local EAGAIN      = const.EAGAIN or 11
local EWOULDBLOCK = const.EWOULDBLOCK or EAGAIN
local EINPROGRESS = const.EINPROGRESS or 115
local EALREADY    = const.EALREADY or 114

-- Where available, reuse nixio’s numeric constants so callers see
-- sensible AF_* / SOCK_* values. Fall back to standard Linux values.
local AF_UNIX     = const.AF_UNIX or 1
local AF_INET     = const.AF_INET or 2
local AF_INET6    = const.AF_INET6 or 10
local SOCK_STREAM = const.SOCK_STREAM or 1
local SOCK_DGRAM  = const.SOCK_DGRAM or 2

local function errno_msg(default, eno)
	if eno == nil or eno == 0 then
		return default
	end

	if type(eno) ~= 'number' then
		local n = tonumber(eno)
		if n then
			eno = n
		else
			eno = nixio.errno()
			if eno == nil or eno == 0 then
				return default
			end
		end
	end

	local s = nixio.strerror(eno)
	if not s or s == '' then
		return default .. ' (errno ' .. tostring(eno) .. ')'
	end
	return s
end

-- nixio APIs vary by build/version in whether they return:
--   nil, msg, errno
-- or
--   nil, errno, msg
-- This helper normalises the trailing two values.
local function norm_msg_eno(a, b)
	local ta, tb = type(a), type(b)

	if ta == 'number' and tb == 'string' then
		return b, a
	end
	if ta == 'string' and tb == 'number' then
		return a, b
	end
	if ta == 'number' and b == nil then
		return nil, a
	end
	if ta == 'string' and b == nil then
		return a, nil
	end
	if ta == 'number' then
		return nil, a
	end
	if tb == 'number' then
		return nil, b
	end
	if ta == 'string' then
		return a, nil
	end
	if tb == 'string' then
		return b, nil
	end
	return nil, nil
end

-- nixio.open expects perms as a mode string (e.g. "0644" or "rw-r--r--")
local DEFAULT_CREATE_PERMS = '0666' -- subject to umask

local function norm_perms(perms)
	if perms == nil then
		return nil
	end
	local t = type(perms)
	if t == 'string' then
		return perms
	end
	if t == 'number' then
		-- Caller may pass decimal 420 (0644) etc; convert to octal string.
		return string.format('%04o', perms)
	end
	return perms
end

local function is_create_mode(mode)
	mode = mode or 'r'
	local c = mode:sub(1, 1)
	return (c == 'w' or c == 'a')
end

----------------------------------------------------------------------
-- Core ops: set_nonblock / read / write / seek / close
----------------------------------------------------------------------

-- fd here is a nixio.File or nixio.Socket
local function set_nonblock(fd)
	if fd and fd.setblocking then
		local ok, a, b = fd:setblocking(false)
		if ok ~= nil and ok ~= false then
			return true, nil, nil
		end
		local msg, eno = norm_msg_eno(a, b)
		eno = eno or nixio.errno()
		return false, errno_msg(msg or 'setblocking(false) failed', eno), eno
	end
	-- If there is no setblocking, treat as already non-blocking.
	return true, nil, nil
end

local function read_fd(fd, max)
	if not fd then
		return nil, 'closed'
	end

	max = max or const.buffersize or 8192
	if max <= 0 then
		return '', nil
	end

	-- nixio.File:read / Socket:read both generally return:
	--   data
	--   nil, msg, errno   OR   nil, errno, msg
	local data, a, b = fd:read(max)

	if type(data) == 'string' then
		-- data may be "" at EOF; that is acceptable to callers.
		return data, nil
	end

	local msg, eno = norm_msg_eno(a, b)
	eno = eno or nixio.errno()

	if eno == EAGAIN or eno == EWOULDBLOCK then
		-- Would block, signal “not ready yet”.
		return nil, nil, 'rd'
	end

	if not eno or eno == 0 then
		-- Treat as EOF.
		return '', nil
	end

	return nil, errno_msg(msg or 'read failed', eno)
end

local function write_fd(fd, str, len)
	if not fd then
		return nil, 'closed'
	end

	len = len or #str
	if len == 0 then
		return 0, nil
	end

	-- For files: File.write(buf, offset, length)
	-- For sockets: Socket.send / write(buf, offset, length) – same shape.
	local n, a, b = fd:write(str, 0, len)

	if type(n) == 'number' then
		return n, nil
	end

	local msg, eno = norm_msg_eno(a, b)
	eno = eno or nixio.errno()

	if eno == EAGAIN or eno == EWOULDBLOCK then
		-- Would block.
		return nil, nil, 'wr'
	end

	return nil, errno_msg(msg or 'write failed', eno)
end

local SEEK_MAP = {
	set     = 'set',
	cur     = 'cur',
	['end'] = 'end',
}

local function seek_fd(fd, whence, off)
	if not fd then
		return nil, 'closed'
	end

	whence = SEEK_MAP[whence] or whence or 'cur'
	off    = off or 0

	if not fd.seek then
		return nil, 'seek not supported on this descriptor'
	end

	local pos, a, b = fd:seek(off, whence)
	if pos == nil then
		local msg, eno = norm_msg_eno(a, b)
		eno = eno or nixio.errno()
		return nil, errno_msg(msg or 'seek failed', eno)
	end
	return pos, nil
end

local function close_fd(fd)
	if not fd then
		return true, nil
	end

	local ok, a, b = fd:close()
	if ok == nil or ok == false then
		local msg, eno = norm_msg_eno(a, b)
		eno = eno or nixio.errno()
		return false, errno_msg(msg or 'close failed', eno)
	end
	return true, nil
end

----------------------------------------------------------------------
-- File-level helpers: mkdir / open_file / pipe / mktemp / fsync / rename / unlink
----------------------------------------------------------------------

-- Basic symbolic permission presets for mkdir and file creation.
local function oct(s)
	return tonumber(s, 8)
end

local permissions = {
	['rw-r--r--'] = oct('644'),
	['rw-rw-rw-'] = oct('666'),

	-- Directories (execute bits are required for traversal).
	['rwxr-xr-x'] = oct('755'),
	['rwx------'] = oct('700'),
}

-- nixio.open tolerates mode strings like "0644" and sometimes symbolic modes.
local function norm_open_perms(perms)
	if perms == nil then return nil end
	local t = type(perms)
	if t == 'number' then
		return string.format('%04o', perms)
	end
	if t == 'string' then
		-- If a symbolic string matches our presets, convert to octal string.
		local m = permissions[perms]
		if m then
			return string.format('%04o', m)
		end
		return perms
	end
	return perms
end

-- nixio.fs.mkdir expects a mode string on some builds ("0755"), not a raw number.
local function norm_mkdir_mode(perms)
	if perms == nil then
		return '0755'
	end

	local t = type(perms)

	if t == 'number' then
		-- Decimal 511 -> "0777"
		return string.format('%04o', perms)
	end

	if t == 'string' then
		local m = permissions[perms]
		if m then
			return string.format('%04o', m)
		end

		-- Accept already-octal strings like "0755"
		-- (and leave other strings untouched for nixio to interpret)
		return perms
	end

	return '0755'
end

local function mkdir_path(path, perms)
	local mode = norm_mkdir_mode(perms)

	local ok, a, b = fs.mkdir(path, mode)
	if ok == nil or ok == false then
		local msg, eno = norm_msg_eno(a, b)
		return false, errno_msg(msg or 'mkdir failed', eno)
	end

	return true, nil
end

local function open_file(path, mode, perms)
	mode = mode or 'r'

	local p = norm_open_perms(perms)

	-- If this is a creating mode and perms is nil, provide a default.
	if p == nil and is_create_mode(mode) then
		p = DEFAULT_CREATE_PERMS
	end

	local f, a, b = nixio.open(path, mode, p)
	if not f then
		local msg, eno = norm_msg_eno(a, b)
		return nil, errno_msg(msg or 'open failed', eno)
	end
	return f, nil
end

local function pipe_fds()
	local r, w, a, b = nixio.pipe()
	if not r then
		local msg, eno = norm_msg_eno(a, b)
		return nil, nil, errno_msg(msg or 'pipe failed', eno)
	end
	return r, w, nil
end

local function mktemp(prefix, perms)
	local start = math.random(1e7)
	local last_err

	local p = norm_open_perms(perms) or '0644'

	for i = start, start + 10 do
		local tmpnam = prefix .. '.' .. i
		local f, a, b = nixio.open(tmpnam, 'w+', p)
		if f then
			return f, tmpnam
		end
		local msg, eno = norm_msg_eno(a, b)
		last_err = errno_msg(msg or 'mktemp open failed', eno)
	end

	return nil, last_err or 'mktemp: failed to create temporary file'
end

local function fsync_fd(fd)
	if not fd or not fd.sync then
		return true, nil
	end
	local ok, a, b = fd:sync(false)
	if ok == nil or ok == false then
		local msg, eno = norm_msg_eno(a, b)
		eno = eno or nixio.errno()
		return false, errno_msg(msg or 'fsync failed', eno)
	end
	return true, nil
end

local function rename_file(oldpath, newpath)
	local ok, a, b = fs.rename(oldpath, newpath)
	if ok == nil or ok == false then
		local msg, eno = norm_msg_eno(a, b)
		return false, errno_msg(msg or 'rename failed', eno)
	end
	return true, nil
end

local function unlink_file(path)
	local ok, a, b = fs.unlink(path)
	if ok == nil or ok == false then
		local msg, eno = norm_msg_eno(a, b)
		return false, errno_msg(msg or 'unlink failed', eno)
	end
	return true, nil
end

-- For this backend, integer open flags are not used; when decode_access
-- is called we can conservatively assume read/write.
local function decode_access(_)
	return true, true
end

local function ignore_sigpipe()
	-- Best-effort ignore of SIGPIPE.
	if nixio.signal and nixio.SIGPIPE then
		local ok, a, b = nixio.signal(nixio.SIGPIPE, 'ign')
		if ok == nil or ok == false then
			local msg, eno = norm_msg_eno(a, b)
			return false, errno_msg(msg or 'signal(SIGPIPE) failed', eno)
		end
	end
	return true, nil
end

----------------------------------------------------------------------
-- Socket helpers
----------------------------------------------------------------------

local function domain_to_str(domain)
	if domain == AF_UNIX then
		return 'unix'
	end
	if AF_INET and domain == AF_INET then
		return 'inet'
	end
	if AF_INET6 and domain == AF_INET6 then
		return 'inet6'
	end
	error('fd_backend.nixio: unsupported address family: ' .. tostring(domain))
end

local function stype_to_str(stype)
	if stype == SOCK_STREAM then
		return 'stream'
	end
	if SOCK_DGRAM and stype == SOCK_DGRAM then
		return 'dgram'
	end
	error('fd_backend.nixio: unsupported socket type: ' .. tostring(stype))
end

-- Normalise sockaddr tokens used by fibers.io.socket:
--   UNIX:
--     "/tmp/sock"
--     { family = "unix", path = "/tmp/sock" }
--   INET:
--     { family = "inet",  host = "127.0.0.1", port = 1234 }
--   INET6:
--     { family = "inet6", host = "::1",       port = 1234 }
local function norm_sockaddr(sa)
	if type(sa) == 'string' then
		return 'unix', sa, 0
	end

	if type(sa) ~= 'table' then
		return nil, nil, nil, 'unsupported sockaddr representation'
	end

	local fam = sa.family or sa.af
	if fam == AF_UNIX then fam = 'unix' end
	if fam == AF_INET then fam = 'inet' end
	if fam == AF_INET6 then fam = 'inet6' end

	if fam == nil then
		-- Reasonable fallback: table with port implies inet.
		if sa.port ~= nil then
			fam = 'inet'
		elseif sa.path then
			fam = 'unix'
		end
	end

	if fam == 'unix' then
		local path = sa.path or sa.host
		if type(path) ~= 'string' or path == '' then
			return nil, nil, nil, 'invalid unix sockaddr'
		end
		return 'unix', path, 0
	end

	if fam == 'inet' or fam == 'inet6' then
		local host = sa.host
		local port = sa.port
		if host ~= nil and type(host) ~= 'string' then
			return nil, nil, nil, 'invalid ' .. fam .. ' host'
		end
		port = tonumber(port)
		if port == nil then
			return nil, nil, nil, 'invalid ' .. fam .. ' port'
		end
		return fam, host, port
	end

	return nil, nil, nil, 'unsupported sockaddr family'
end

--- socket(domain, stype, protocol) -> fd|nil, err|nil, eno|nil
local function socket_fd(domain, stype, _)
	local d = domain_to_str(domain)
	local t = stype_to_str(stype)

	local s, a, b = nixio.socket(d, t)
	if not s then
		local msg, eno = norm_msg_eno(a, b)
		return nil, errno_msg(msg or 'socket failed', eno), eno
	end
	-- Returned “fd” is a nixio.Socket object.
	return s, nil, nil
end

--- bind(fd, sa) where fd is nixio.Socket
local function bind_fd(fd, sa)
	if not fd then
		return false, 'closed socket', nil
	end

	local fam, host, port, nerr = norm_sockaddr(sa)
	if not fam then
		return false, nerr, nil
	end

	local ok, a, b
	ok, a, b = fd:bind(host, port)

	if ok == nil or ok == false then
		local msg, eno = norm_msg_eno(a, b)
		eno = eno or nixio.errno()
		return false, errno_msg(msg or 'bind failed', eno), eno
	end

	return true, nil, nil
end

local function listen_fd(fd)
	if not fd then
		return false, 'closed socket', nil
	end

	local backlog = const.SOMAXCONN or 128
	local ok, a, b = fd:listen(backlog)
	if ok == nil or ok == false then
		local msg, eno = norm_msg_eno(a, b)
		eno = eno or nixio.errno()
		return false, errno_msg(msg or 'listen failed', eno), eno
	end
	return true, nil, nil
end

--- accept(fd) -> newfd|nil, err|nil, again:boolean
local function accept_fd(fd)
	if not fd then
		return nil, 'closed socket', false
	end

	-- nixio.Socket.accept() -> newsock, host, port | nil, msg, errno
	-- Some builds may swap msg/errno on error; normalise.
	local newsock, x, y = fd:accept()
	if newsock then
		return newsock, nil, false
	end

	local msg, eno = norm_msg_eno(x, y)
	eno = eno or nixio.errno()
	if eno == EAGAIN or eno == EWOULDBLOCK then
		return nil, nil, true
	end

	return nil, errno_msg(msg or 'accept failed', eno), false
end

--- connect_start(fd, sa) -> ok|nil, err|nil, inprogress:boolean
local function connect_start_fd(fd, sa)
	if not fd then
		return nil, 'closed socket', false
	end

	local fam, host, port, nerr = norm_sockaddr(sa)
	if not fam then
		return nil, nerr, false
	end

	local ok, a, b = fd:connect(host, port)
	if ok then
		return true, nil, false
	end

	local msg, eno = norm_msg_eno(a, b)
	eno = eno or nixio.errno()
	if eno == EINPROGRESS or eno == EALREADY or eno == EAGAIN then
		-- Non-blocking connect in progress.
		return nil, nil, true
	end

	return nil, errno_msg(msg or 'connect failed', eno), false
end

--- connect_finish(fd) -> ok:boolean, err|nil
local function connect_finish_fd(fd)
	if not fd then
		return false, 'closed socket'
	end

	if not fd.getopt then
		-- Fallback: if we cannot inspect SO_ERROR, assume success.
		return true, nil
	end

	local soerr, a, b = fd:getopt('socket', 'error')
	if soerr == nil then
		local msg, eno = norm_msg_eno(a, b)
		eno = eno or nixio.errno()
		return false, errno_msg(msg or 'getsockopt(SO_ERROR) failed', eno)
	end

	soerr = tonumber(soerr) or 0
	if soerr == 0 then
		return true, nil
	end

	return false, errno_msg('connect error', soerr)
end

----------------------------------------------------------------------
-- Capability probe
----------------------------------------------------------------------

local function is_supported()
	-- If this module loaded, nixio was already required successfully.
	return true
end

----------------------------------------------------------------------
-- Assemble ops and build backend
----------------------------------------------------------------------

local ops = {
	-- Core file/socket descriptor ops
	set_nonblock = set_nonblock,
	read         = read_fd,
	write        = write_fd,
	seek         = seek_fd,
	close        = close_fd,

	-- File-level helpers
	open_file      = open_file,
	pipe           = pipe_fds,
	mktemp         = mktemp,
	fsync          = fsync_fd,
	rename         = rename_file,
	unlink         = unlink_file,
	mkdir          = mkdir_path,
	decode_access  = decode_access,
	ignore_sigpipe = ignore_sigpipe,

	-- Socket-level helpers
	socket         = socket_fd,
	bind           = bind_fd,
	listen         = listen_fd,
	accept         = accept_fd,
	connect_start  = connect_start_fd,
	connect_finish = connect_finish_fd,

	-- Metadata for callers
	modes       = {},  -- nixio uses mode strings for open()
	permissions = permissions,

	AF_UNIX     = AF_UNIX,
	AF_INET     = AF_INET,
	AF_INET6    = AF_INET6,
	SOCK_STREAM = SOCK_STREAM,
	SOCK_DGRAM  = SOCK_DGRAM,

	is_supported = is_supported,
}

return core.build_backend(ops)
