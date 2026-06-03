-- fibers/io/socket.lua
--
-- Socket helpers on top of fd_backend + stream.
--
-- Exposes:
--   socket(domain, stype, protocol?) -> Socket
--   listen_unix(path, opts?)         -> Socket (listening AF_UNIX)
--   connect_unix(path, stype?, proto?) -> Stream
--   listen_inet(host, port, opts?)   -> Socket (listening AF_INET)
--   connect_inet(host, port, opts?)  -> Stream
--
-- Socket supports:
--   :bind(sa)
--   :listen()
--   :listen_unix(path)
--   :listen_inet(host, port)
--   :accept_op()
--   :accept()
--   :connect_op(sa)
--   :connect(sa)
--   :connect_unix_op(path)
--   :connect_unix(path)
--   :connect_inet_op(host, port)
--   :connect_inet(host, port)
--   :close()
--
---@module 'fibers.io.socket'

local wait       = require 'fibers.wait'
local poller_mod = require 'fibers.io.poller'
local fd_backend = require 'fibers.io.fd_backend'
local stream_mod = require 'fibers.io.stream'
local perform    = require 'fibers.performer'.perform

---@class Socket
---@field fd integer|nil
local Socket = {}
Socket.__index = Socket

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Wrap an fd as a full-duplex Stream.
---@param fd integer
---@param filename? string
---@return Stream
local function fd_to_stream(fd, filename)
	local io = fd_backend.new(fd, { filename = filename })
	return stream_mod.open(io, true, true)
end

--- Create a new non-blocking socket object from an fd.
---@param fd integer
---@return Socket
local function new_socket(fd)
	local ok, err = fd_backend.set_nonblock(fd)
	if not ok then
		fd_backend.close_fd(fd)
		error('set_nonblock(socket fd) failed: ' .. tostring(err))
	end
	return setmetatable({ fd = fd }, Socket)
end

--- Return underlying fd or error if closed.
---@return integer
function Socket:_fd()
	local fd = self.fd
	assert(fd, 'socket is closed')
	return fd
end

--- Build an AF_INET sockaddr token understood by fd_backend.
---@param host string
---@param port number|string
---@return table|nil sa, any err
local function inet_sa(host, port)
	if type(host) ~= 'string' or host == '' then
		return nil, 'host must be a non-empty string'
	end

	port = tonumber(port)
	if not port or port < 0 or port > 65535 then
		return nil, 'port must be 0..65535'
	end

	return {
		family = 'inet',
		host   = host,
		port   = math.floor(port),
	}
end

----------------------------------------------------------------------
-- Constructors
----------------------------------------------------------------------

--- Create a new non-blocking socket via the backend.
---@param domain integer
---@param stype integer
---@param protocol? integer
---@return Socket|nil s, any err
local function socket(domain, stype, protocol)
	local fd, err = fd_backend.socket(domain, stype, protocol or 0)
	if not fd then
		return nil, err
	end

	local ok, nerr = fd_backend.set_nonblock(fd)
	if not ok then
		fd_backend.close_fd(fd)
		return nil, nerr
	end

	return new_socket(fd)
end

----------------------------------------------------------------------
-- Generic bind/listen helpers
----------------------------------------------------------------------

--- Bind this socket to an address token (UNIX path string or inet table).
---@param sa any
---@return boolean|nil ok, any err
function Socket:bind(sa)
	local fd = self:_fd()
	local ok, err = fd_backend.bind(fd, sa)
	if not ok then
		return nil, ('bind failed: %s'):format(tostring(err))
	end
	return true
end

--- Mark this socket as listening.
---@return boolean|nil ok, any err
function Socket:listen()
	local fd = self:_fd()
	local ok, err = fd_backend.listen(fd)
	if not ok then
		return nil, ('listen failed: %s'):format(tostring(err))
	end
	return true
end

----------------------------------------------------------------------
-- Listening and address helpers (UNIX / INET)
----------------------------------------------------------------------

--- Listen on a UNIX-domain path using this Socket.
---@param path string
---@return boolean|nil ok, any err
function Socket:listen_unix(path)
	local ok, err = self:bind(path)
	if not ok then
		return nil, err
	end
	return self:listen()
end

--- Bind this socket to an IPv4 address/port.
---@param host string
---@param port number|string
---@return boolean|nil ok, any err
function Socket:bind_inet(host, port)
	local sa, err = inet_sa(host, port)
	if not sa then
		return nil, err
	end
	return self:bind(sa)
end

--- Listen on an IPv4 address/port using this Socket.
---@param host string
---@param port number|string
---@return boolean|nil ok, any err
function Socket:listen_inet(host, port)
	local ok, err = self:bind_inet(host, port)
	if not ok then
		return nil, err
	end
	return self:listen()
end

----------------------------------------------------------------------
-- accept() as an Op
----------------------------------------------------------------------

--- Build an Op that accepts a connection and returns a Stream.
---@return Op
function Socket:accept_op()
	local P  = poller_mod.get()
	local fd = self:_fd()

	local function step()
		local new_fd, err, again = fd_backend.accept(fd)
		if new_fd then
			return true, new_fd, nil
		end
		if again then
			return false
		end
		return true, nil, err
	end

	local function register(task)
		return P:wait(fd, 'rd', task)
	end

	local function wrap(new_fd, err)
		if not new_fd then
			return nil, err
		end
		return fd_to_stream(new_fd)
	end

	return wait.waitable(register, step, wrap)
end

--- Accept a connection synchronously into a Stream.
---@return Stream|nil client, any err
function Socket:accept()
	return perform(self:accept_op())
end

----------------------------------------------------------------------
-- connect() as an Op (generic sockaddr token)
----------------------------------------------------------------------

--- Build an Op that connects this Socket to an address token.
--- sa may be:
---   * UNIX path string
---   * { family = 'inet', host = '1.2.3.4', port = 1234 }
---@param sa any
---@return Op
function Socket:connect_op(sa)
	local P     = poller_mod.get()
	local fd    = self:_fd()
	local state = 'initial'

	local function step()
		if state == 'initial' then
			local ok, err, inprogress = fd_backend.connect_start(fd, sa)
			if ok then
				return true, true, nil
			end
			if inprogress then
				state = 'waiting'
				return false
			end
			return true, false, err
		elseif state == 'waiting' then
			local ok, err = fd_backend.connect_finish(fd)
			if not ok then
				return true, false, err
			end
			return true, true, nil
		else
			return true, false, 'invalid connect state'
		end
	end

	local function register(task)
		return P:wait(fd, 'wr', task)
	end

	local function wrap(ok, err)
		if not ok then
			return nil, err
		end
		local new_fd = fd
		self.fd = nil -- hand ownership to Stream
		return fd_to_stream(new_fd)
	end

	return wait.waitable(register, step, wrap)
end

--- Connect synchronously and return a Stream.
---@param sa any
---@return Stream|nil stream, any err
function Socket:connect(sa)
	return perform(self:connect_op(sa))
end

----------------------------------------------------------------------
-- UNIX-domain convenience
----------------------------------------------------------------------

--- Build an Op that connects this socket to a UNIX-domain path.
---@param path string
---@return Op
function Socket:connect_unix_op(path)
	return self:connect_op(path)
end

--- Connect synchronously to a UNIX-domain path.
---@param path string
---@return Stream|nil stream, any err
function Socket:connect_unix(path)
	return perform(self:connect_unix_op(path))
end

--- Listen on a UNIX-domain path and return a listening Socket.
---@param path string
---@param opts? { stype?: integer, protocol?: integer, ephemeral?: boolean }
---@return Socket|nil s, any err
local function listen_unix(path, opts)
	opts = opts or {}

	local stype    = opts.stype or fd_backend.SOCK_STREAM
	local protocol = opts.protocol or 0

	local s, err = socket(fd_backend.AF_UNIX, stype, protocol)
	if not s then
		return nil, err
	end

	local ok, lerr = s:listen_unix(path)
	if not ok then
		s:close()
		return nil, lerr
	end

	if opts.ephemeral then
		local parent_close = s.close
		function s:close()
			local ok1, err1 = parent_close(self)

			local ok2, err2 = fd_backend.unlink(path)
			if not ok2 then
				return false, ('failed to remove %s: %s'):format(
					tostring(path),
					tostring(err2)
				)
			end

			if ok1 == false then
				return false, err1
			end
			return true, nil
		end
	end

	return s
end

--- Connect to a UNIX-domain socket path and return a Stream.
---@param path string
---@param stype? integer
---@param protocol? integer
---@return Stream|nil stream, any err
local function connect_unix(path, stype, protocol)
	stype    = stype or fd_backend.SOCK_STREAM
	protocol = protocol or 0

	local s, err = socket(fd_backend.AF_UNIX, stype, protocol)
	if not s then
		return nil, err
	end

	local stream, cerr = s:connect_unix(path)
	if not stream then
		s:close()
		return nil, cerr
	end
	return stream
end

----------------------------------------------------------------------
-- AF_INET convenience
----------------------------------------------------------------------

--- Build an Op that connects this socket to an IPv4 host/port.
---@param host string
---@param port number|string
---@return Op
function Socket:connect_inet_op(host, port)
	local sa, err = inet_sa(host, port)
	if not sa then
		error(err, 2)
	end
	return self:connect_op(sa)
end

--- Connect synchronously to an IPv4 host/port.
---@param host string
---@param port number|string
---@return Stream|nil stream, any err
function Socket:connect_inet(host, port)
	return perform(self:connect_inet_op(host, port))
end

--- Listen on an IPv4 address/port and return a listening Socket.
---@param host string
---@param port number|string
---@param opts? { stype?: integer, protocol?: integer }
---@return Socket|nil s, any err
local function listen_inet(host, port, opts)
	opts = opts or {}

	local stype    = opts.stype or fd_backend.SOCK_STREAM
	local protocol = opts.protocol or 0

	local s, err = socket(fd_backend.AF_INET, stype, protocol)
	if not s then
		return nil, err
	end

	local ok, lerr = s:listen_inet(host, port)
	if not ok then
		s:close()
		return nil, lerr
	end

	return s
end

--- Connect to an IPv4 host/port and return a Stream.
--- opts.bind_host / opts.bind_port can be used to bind a source address/port first.
---@param host string
---@param port number|string
---@param opts? { stype?: integer, protocol?: integer, bind_host?: string, bind_port?: number|string }
---@return Stream|nil stream, any err
local function connect_inet(host, port, opts)
	opts = opts or {}

	local stype    = opts.stype or fd_backend.SOCK_STREAM
	local protocol = opts.protocol or 0

	local s, err = socket(fd_backend.AF_INET, stype, protocol)
	if not s then
		return nil, err
	end

	if opts.bind_host ~= nil or opts.bind_port ~= nil then
		local ok, berr = s:bind_inet(opts.bind_host or '0.0.0.0', opts.bind_port or 0)
		if not ok then
			s:close()
			return nil, berr
		end
	end

	local stream, cerr = s:connect_inet(host, port)
	if not stream then
		s:close()
		return nil, cerr
	end

	return stream
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

--- Close the underlying socket fd.
---@return boolean ok, any err
function Socket:close()
	if self.fd then
		local ok, err = fd_backend.close_fd(self.fd)
		self.fd = nil
		return ok, err
	end
	return true, nil
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	socket       = socket,

	listen_unix  = listen_unix,
	connect_unix = connect_unix,

	listen_inet  = listen_inet,
	connect_inet = connect_inet,

	Socket       = Socket,

	-- re-export useful constants for callers
	AF_UNIX     = fd_backend.AF_UNIX,
	AF_INET     = fd_backend.AF_INET,
	SOCK_STREAM = fd_backend.SOCK_STREAM,
}
