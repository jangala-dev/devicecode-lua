-- fibers/io/file.lua
--
-- File-backed streams on top of fd_backend + stream.
--
-- Exposes:
--   fdopen(fd, flags_or_mode[, filename]) -> Stream
--   open(filename[, mode[, perms]])       -> Stream | nil, err
--   pipe()                                -> read_stream, write_stream
--   mktemp(prefix[, perms])               -> fd, tmpname_or_err
--   tmpfile([perms[, tmpdir]])            -> Stream (auto-unlink on close)
--   init_nonblocking(fd)                  -> ok, err|nil
--
---@module 'fibers.io.file'

local stream  = require 'fibers.io.stream'
local fd_back = require 'fibers.io.fd_backend'

-- Best-effort: ignore SIGPIPE so write failures report via errno/return codes.
do
	if fd_back.ignore_sigpipe then
		fd_back.ignore_sigpipe() -- errors are treated as non-fatal
	end
end

----------------------------------------------------------------------
-- Mode / permission policy (OS-agnostic)
----------------------------------------------------------------------

-- We keep the string conventions, but leave numeric mapping to the backend.
---@param mode string The file mode string (e.g., "r", "w", "a", "r+", "w+", "a+")
---@return boolean readable Returns true if the mode allows reading
---@return boolean writable Returns true if the mode allows writing
local function mode_access(mode)
	assert(type(mode) == 'string', 'mode must be a string')
	local plus = mode:find('+', 1, true) ~= nil
	local c    = mode:sub(1, 1)

	if c == 'r' then
		if plus then
			return true, true
		else
			return true, false
		end
	elseif c == 'w' or c == 'a' then
		if plus then
			return true, true
		else
			return false, true
		end
	else
		error('invalid mode: ' .. tostring(mode))
	end
end

----------------------------------------------------------------------
-- Internal: wrap an fd as a Stream
----------------------------------------------------------------------

--- Wrap an fd in a Stream using fd_backend.
---
--- flags_or_mode may be:
---   * number : backend-specific open flags (decode_access will be used)
---   * string : Lua-style mode string ("r", "w+", "rb", etc.)
---   * table  : { readable = bool, writable = bool }
---
---@param fd integer
---@param flags_or_mode any
---@param filename? string
---@return Stream
local function fdopen(fd, flags_or_mode, filename)
	-- assert(type(fd) == "number", "fdopen: fd must be a number")
	assert(fd ~= nil, 'fdopen: fd must be non-nil')

	local readable, writable

	local t = type(flags_or_mode)
	if t == 'number' then
		assert(fd_back.decode_access, 'backend does not implement decode_access')
		readable, writable = fd_back.decode_access(flags_or_mode)
	elseif t == 'string' then
		readable, writable = mode_access(flags_or_mode)
	elseif t == 'table' then
		readable = not not flags_or_mode.readable
		writable = not not flags_or_mode.writable
	else
		error('fdopen: invalid flags_or_mode: ' .. tostring(flags_or_mode))
	end

	local io = fd_back.new(fd, { filename = filename })

	-- We no longer try to adjust buffer size based on fstat; stream.open
	-- will apply its default buffer sizes.
	return stream.open(io, readable, writable)
end

----------------------------------------------------------------------
-- Directories
----------------------------------------------------------------------

--- Create a directory.
---
--- perms may be an integer mask or a symbolic string understood by the backend.
---@param path string
---@param perms? integer|string
---@return boolean|nil ok, string|nil err
local function mkdir(path, perms)
	assert(type(path) == 'string' and path ~= '', 'mkdir: path must be a non-empty string')

	if not fd_back.mkdir then
		return nil, 'backend does not implement mkdir'
	end

	return fd_back.mkdir(path, perms)
end

--- Best-effort classification of "already exists" errors across backends.
---@param err any
---@return boolean
local function is_eexist(err)
	if err == nil then return false end
	local s = tostring(err):lower()
	-- Common shapes: "EEXIST", "file exists", "exists"
	return s:find('eexist', 1, true) ~= nil
		or s:find('file exists', 1, true) ~= nil
		or s:find('exists', 1, true) ~= nil
end

--- Create a directory path (mkdir -p).
---
--- Semantics:
---   * creates parent components as required
---   * succeeds if the directory already exists
---   * returns nil,err on the first hard failure encountered
---
--- perms may be an integer mask or a symbolic string understood by the backend.
---@param path string
---@param perms? integer|string
---@return boolean|nil ok, string|nil err
local function mkdir_p(path, perms)
	assert(type(path) == 'string' and path ~= '', 'mkdir_p: path must be a non-empty string')

	if not fd_back.mkdir then
		return nil, 'backend does not implement mkdir'
	end

	-- Root is trivially present.
	if path == '/' then
		return true, nil
	end

	-- Normalise repeated slashes; keep leading '/' if present.
	local is_abs = path:sub(1, 1) == '/'
	-- Collapse multiple slashes to single slash.
	path = path:gsub('/+', '/')

	-- Strip trailing slash (except for "/").
	if #path > 1 and path:sub(-1) == '/' then
		path = path:sub(1, -2)
	end

	-- Split into components.
	local parts = {}
	for seg in path:gmatch('[^/]+') do
		-- Skip "." segments; do not attempt to resolve ".." here.
		if seg ~= '.' and seg ~= '' then
			parts[#parts + 1] = seg
		end
	end

	-- Nothing to do (e.g. "." or "/.").
	if #parts == 0 then
		return true, nil
	end

	local cur = is_abs and '' or nil
	for i = 1, #parts do
		local seg = parts[i]
		if cur == nil then
			cur = seg
		elseif cur == '' then
			cur = '/' .. seg
		else
			cur = cur .. '/' .. seg
		end

		local ok, err = fd_back.mkdir(cur, perms)
		if ok then
			-- created
		else
			-- treat "already exists" as success; anything else is fatal
			if not is_eexist(err) then
				return nil, err
			end
		end
	end

	return true, nil
end

----------------------------------------------------------------------
-- Open by filename
----------------------------------------------------------------------

--- Open a file by name as a Stream.
---
--- mode   : "r", "w", "a", "r+", "w+", "a+" (with optional "b" suffix)
--- perms  : integer or symbolic string (e.g. "rw-rw-rw-"), backend-defined.
---
---@param filename string
---@param mode? string
---@param perms? integer|string
---@return Stream|nil f, string|nil err
local function open_file(filename, mode, perms)
	mode = mode or 'r'

	local fd, err = fd_back.open_file(filename, mode, perms)
	if not fd then
		return nil, err
	end

	return fdopen(fd, mode, filename)
end

----------------------------------------------------------------------
-- Pipes
----------------------------------------------------------------------

--- Create a unidirectional pipe as two Streams (read, write).
---@return Stream r_stream, Stream w_stream
local function pipe()
	local rd, wr, err = fd_back.pipe()
	if not rd then
		error(err or 'pipe() failed')
	end

	local r_stream = fdopen(rd, 'r')
	local w_stream = fdopen(wr, 'w')
	return r_stream, w_stream
end

----------------------------------------------------------------------
-- mktemp / tmpfile
----------------------------------------------------------------------

--- Create a temporary file with a unique name (backend-level).
---
--- perms may be an integer mask or a symbolic string understood by the backend.
---@param prefix string
---@param perms? integer|string
---@return integer|nil fd, string tmpname_or_err
local function mktemp(prefix, perms)
	perms = perms or 'rw-r--r--'
	local fd, tmpnam_or_err = fd_back.mktemp(prefix, perms)
	if not fd then
		return nil, tmpnam_or_err
	end
	return fd, tmpnam_or_err
end

--- Create a temporary file wrapped as a Stream, with unlink-on-close semantics.
---@param perms? integer|string
---@param tmpdir? string
---@return Stream|nil f, string|nil err
local function tmpfile(perms, tmpdir)
	perms  = perms or 'rw-r--r--'
	tmpdir = tmpdir or os.getenv('TMPDIR') or '/tmp'
	---@cast tmpdir string

	local fd, tmpnam_or_err = mktemp(tmpdir .. '/tmp', perms)
	if not fd then
		return nil, tmpnam_or_err
	end

	---@type Stream
	local f = fdopen(fd, 'r+', tmpnam_or_err)

	-- We want unlink-on-close semantics by default, with a way to
	-- disable that via :rename().
	local io = f.io
	assert(io, 'tmpfile backend missing')
	---@cast io StreamBackend

	local old_close = assert(io.close, 'tmpfile backend missing close()')

	--- Rename the temporary file and disable unlink-on-close behaviour.
	---@param newname string
	---@return boolean|nil ok, string|nil err
	function f:rename(newname)
		-- Flush buffered data first.
		self:flush()

		local real_fd = io.fileno and io:fileno() or fd
		if real_fd then
			fd_back.fsync(real_fd)
		end

		local fname = assert(io.filename, 'tmpfile has no filename')
		local ok, err = fd_back.rename(fname, newname)
		if not ok then
			return nil, ('failed to rename %s to %s: %s'):format(
				tostring(fname),
				tostring(newname),
				tostring(err)
			)
		end

		io.filename = newname
		-- Disable remove-on-close: restore original close.
		io.close = old_close
		return true
	end

	--- Close the fd and unlink the temporary file.
	---@return boolean ok, string|nil err
	function io:close()
		local ok, err = old_close(self)
		if not ok then
			return ok, err
		end

		local fname = assert(self.filename, 'tmpfile has no filename')
		local ok2, err2 = fd_back.unlink(fname)
		if not ok2 then
			return false, ('failed to remove %s: %s'):format(
				tostring(fname),
				tostring(err2)
			)
		end

		return true, nil
	end

	return f
end

----------------------------------------------------------------------
-- Compatibility helper
----------------------------------------------------------------------

--- Put an fd into non-blocking mode using the backend.
---@param fd integer
---@return boolean ok, string|nil err
local function init_nonblocking(fd)
	return fd_back.set_nonblock(fd)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	fdopen           = fdopen,
	open             = open_file,
	pipe             = pipe,
	mktemp           = mktemp,
	tmpfile          = tmpfile,
	init_nonblocking = init_nonblocking,
	mkdir            = mkdir,
	mkdir_p          = mkdir_p,
	rename           = fd_back.rename,
	unlink           = fd_back.unlink,

	-- For callers that previously used file.modes / file.permissions,
	-- re-export backend metadata if present.
	modes       = fd_back.modes or {},
	permissions = fd_back.permissions or {},
}
