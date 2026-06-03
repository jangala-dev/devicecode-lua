-- fibers/io/fd_backend/core.lua

local poller = require 'fibers.io.poller'

---@class FdBackend
---@field filename string|nil
---@field _fd integer|nil
---@field _ops table
local FdBackend = {}
FdBackend.__index = FdBackend

function FdBackend:kind()
	return 'fd'
end

function FdBackend:fileno()
	return self._fd
end

function FdBackend:read_string(max)
	if not self._fd then
		return nil, 'closed'
	end

	max = max or 4096
	if max <= 0 then
		return '', nil
	end

	return self._ops.read(self._fd, max)
end

function FdBackend:write_string(str)
	if not self._fd then
		return nil, 'closed'
	end

	local len = #str
	if len == 0 then
		return 0, nil
	end

	return self._ops.write(self._fd, str, len)
end

function FdBackend:seek(whence, off)
	if not self._fd then
		return nil, 'closed'
	end
	return self._ops.seek(self._fd, whence, off)
end

function FdBackend:on_readable(task)
	return poller.get():wait(assert(self._fd, 'closed fd'), 'rd', task)
end

function FdBackend:on_writable(task)
	return poller.get():wait(assert(self._fd, 'closed fd'), 'wr', task)
end

function FdBackend:close()
	if self._fd == nil then
		return true, nil
	end

	local fd = self._fd
	self._fd = nil

	return self._ops.close(fd)
end

----------------------------------------------------------------------
-- Backend builder
----------------------------------------------------------------------

--- Build a concrete fd backend module from low-level ops.
---
--- Required ops:
---   mkdir(path[, perms]) -> ok:boolean, err|nil
---   set_nonblock(fd) -> ok:boolean, err|nil
---   read(fd, max)    -> s|nil, err|nil, want?
---   write(fd, s, len)-> n|nil, err|nil, want?
---   seek(fd, whence, off) -> pos|nil, err|nil
---   close(fd)        -> ok:boolean, err|nil
---
--- Optional file ops (used by fibers.io.file):
---   open_file(path, mode, perms) -> fd|nil, err|nil
---   pipe() -> rd_fd|nil, wr_fd|nil, err|nil
---   mktemp(prefix, perms) -> fd|nil, tmpname_or_err
---   fsync(fd) -> ok:boolean, err|nil
---   rename(old, new) -> ok:boolean, err|nil
---   unlink(path) -> ok:boolean, err|nil
---   decode_access(flags) -> readable:boolean, writable:boolean
---   ignore_sigpipe() -> ok:boolean, err|nil
---
--- Optional socket ops (used by fibers.io.socket):
---   socket(domain, stype, protocol) -> fd|nil, err|nil
---   bind(fd, sa) -> ok:boolean, err|nil
---   listen(fd) -> ok:boolean, err|nil
---   accept(fd) -> newfd|nil, err|nil, again:boolean
---   connect_start(fd, sa) -> ok:boolean|nil, err|nil, inprogress:boolean
---   connect_finish(fd) -> ok:boolean, err|nil
---
--- Optional metadata:
---   modes        : table<string, integer>
---   permissions  : table<string, integer>
---   AF_UNIX      : integer
---   SOCK_STREAM  : integer
---   is_supported() -> boolean
---
---@param ops table
---@return table backend_module
local function build_backend(ops)
	local required = { 'set_nonblock', 'read', 'write', 'seek', 'close' }
	for _, k in ipairs(required) do
		assert(type(ops[k]) == 'function',
			'fd_backend ops.' .. k .. ' must be a function')
	end

	local function new(fd, opts)
		opts = opts or {}

		if fd ~= nil then
			local ok, err = ops.set_nonblock(fd)
			if not ok then
				error('fd_backend: set_nonblock(' .. tostring(fd) .. ') failed: '
					.. tostring(err))
			end
		end

		local self = {
			_fd      = fd,
			_ops     = ops,
			filename = opts.filename,
		}
		return setmetatable(self, FdBackend)
	end

	local function is_supported()
		if type(ops.is_supported) == 'function' then
			return not not ops.is_supported()
		end
		return true
	end

	--------------------------------------------------------------------
	-- File-level helpers
	--------------------------------------------------------------------

	local function mkdir(path, perms)
		assert(type(ops.mkdir) == 'function',
			'fd_backend backend does not implement mkdir')
		return ops.mkdir(path, perms)
	end

	local function open_file(path, mode, perms)
		assert(type(ops.open_file) == 'function',
			'fd_backend backend does not implement open_file')
		return ops.open_file(path, mode, perms)
	end

	local function pipe()
		assert(type(ops.pipe) == 'function',
			'fd_backend backend does not implement pipe')
		return ops.pipe()
	end

	local function mktemp(prefix, perms)
		assert(type(ops.mktemp) == 'function',
			'fd_backend backend does not implement mktemp')
		return ops.mktemp(prefix, perms)
	end

	local function fsync(fd)
		if not ops.fsync then
			return true, nil
		end
		return ops.fsync(fd)
	end

	local function rename(oldpath, newpath)
		assert(type(ops.rename) == 'function',
			'fd_backend backend does not implement rename')
		return ops.rename(oldpath, newpath)
	end

	local function unlink(path)
		assert(type(ops.unlink) == 'function',
			'fd_backend backend does not implement unlink')
		return ops.unlink(path)
	end

	local function decode_access(flags)
		if not ops.decode_access then
			error('fd_backend backend does not implement decode_access')
		end
		return ops.decode_access(flags)
	end

	local function ignore_sigpipe()
		if ops.ignore_sigpipe then
			return ops.ignore_sigpipe()
		end
		return true, nil
	end

	local function init_nonblocking(fd)
		return ops.set_nonblock(fd)
	end

	local function close_fd(fd)
		return ops.close(fd)
	end

	--------------------------------------------------------------------
	-- Socket-level helpers (optional)
	--------------------------------------------------------------------

	local function socket(domain, stype, protocol)
		if not ops.socket then
			error('fd_backend backend does not implement socket()')
		end
		return ops.socket(domain, stype, protocol or 0)
	end

	local function bind(fd, sa)
		if not ops.bind then
			error('fd_backend backend does not implement bind()')
		end
		return ops.bind(fd, sa)
	end

	local function listen(fd)
		if not ops.listen then
			error('fd_backend backend does not implement listen()')
		end
		return ops.listen(fd)
	end

	--- accept(fd) -> newfd|nil, err|nil, again:boolean
	local function accept(fd)
		if not ops.accept then
			error('fd_backend backend does not implement accept()')
		end
		local newfd, err, again = ops.accept(fd)
		return newfd, err, again
	end

	--- connect_start(fd, sa) -> ok|nil, err|nil, inprogress:boolean
	local function connect_start(fd, sa)
		if not ops.connect_start then
			error('fd_backend backend does not implement connect_start()')
		end
		local ok, err, inprogress = ops.connect_start(fd, sa)
		return ok, err, inprogress
	end

	--- connect_finish(fd) -> ok:boolean, err|nil
	local function connect_finish(fd)
		if not ops.connect_finish then
			error('fd_backend backend does not implement connect_finish()')
		end
		return ops.connect_finish(fd)
	end

	return {
		new          = new,
		is_supported = is_supported,

		-- low-level helper
		set_nonblock = init_nonblocking,
		close_fd     = close_fd,

		-- file-level helpers
		mkdir          = mkdir,
		open_file      = open_file,
		pipe           = pipe,
		mktemp         = mktemp,
		fsync          = fsync,
		rename         = rename,
		unlink         = unlink,
		decode_access  = decode_access,
		ignore_sigpipe = ignore_sigpipe,

		-- socket-level helpers
		socket         = socket,
		bind           = bind,
		listen         = listen,
		accept         = accept,
		connect_start  = connect_start,
		connect_finish = connect_finish,

		-- metadata (if provided)
		modes       = ops.modes or {},
		permissions = ops.permissions or {},
		AF_UNIX     = ops.AF_UNIX,
		AF_INET     = ops.AF_INET,
		SOCK_STREAM = ops.SOCK_STREAM,
	}
end

return {
	build_backend = build_backend,
}
