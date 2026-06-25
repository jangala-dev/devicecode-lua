-- services/http/transport/terminate.lua
-- Immediate backend termination helpers. These are the only transport-level
-- helpers intended for finaliser-safe shutdown paths. Graceful protocol close
-- remains Op-based work owned by callers.

local safe = require 'coxpcall'

local M = {}

local unpack = rawget(table, 'unpack') or _G.unpack

local function call(method, obj, ...)
	if obj and type(obj[method]) == 'function' then
		local args = { n = select('#', ...), ... }
		return safe.pcall(function () return obj[method](obj, unpack(args, 1, args.n)) end)
	end
	return false, 'method_missing'
end

local function get_field(obj, key)
	if not obj then return nil end
	local ok, value = safe.pcall(function () return obj[key] end)
	if ok then return value end
	return nil
end

local function take_and_close_connection_socket(obj)
	local conn = get_field(obj, 'connection')
	if not conn then return false, 'connection_missing' end

	-- lua-http exposes h1 stream.connection and h1_connection:take_socket().  In
	-- cancellation cleanup we need a transport boundary, not a graceful protocol
	-- shutdown.  Taking the cqueues socket and closing that socket lets cqueues
	-- cancel its descriptor before close, which is the ordering cqueues requires.
	if type(conn.take_socket) == 'function' then
		local ok, sock = safe.pcall(function () return conn:take_socket() end)
		if ok and sock then
			local closed = call('close', sock)
			if closed then return true end
		end
	end

	return false, 'take_socket_unavailable'
end

function M.terminate_stream(stream, reason)
	if not stream then return true end
	local ok = take_and_close_connection_socket(stream)
	if ok then return true end
	ok = call('terminate', stream, reason or 'terminated')
	if ok then return true end
	ok = call('close', stream)
	if ok then return true end
	-- Last resort only.  lua-http shutdown can be graceful and should not be the
	-- first action on timeout/finaliser cleanup.
	ok = call('shutdown', stream)
	if ok then return true end
	return true
end

function M.terminate_server(server, reason)
	if not server then return true end
	local ok = call('close', server)
	if ok then return true end
	return true
end

function M.terminate_websocket(ws, reason)
	if not ws then return true end
	-- This is deliberately not graceful. It gives lua-http/cqueues a bounded
	-- immediate wake/close path for finalisers and service shutdown.
	local ok = call('close', ws, 1006, reason or 'terminated', 0)
	if ok then return true end
	ok = call('shutdown', ws)
	if ok then return true end
	return true
end

function M.terminate_request(req, reason)
	if not req then return true end
	local ok = take_and_close_connection_socket(req)
	if ok then return true end
	ok = call('terminate', req, reason or 'terminated')
	if ok then return true end
	ok = call('cancel', req, reason or 'terminated')
	if ok then return true end
	ok = call('close', req)
	if ok then return true end
	ok = call('shutdown', req)
	if ok then return true end
	return true
end

return M
