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
	if obj == nil then return nil end
	local ok, value = safe.pcall(function () return obj[key] end)
	if ok then return value end
	return nil
end

local function take_and_close_socket_from_connection(conn)
	if conn == nil or type(conn.take_socket) ~= 'function' then
		return false, 'take_socket_unavailable'
	end

	local ok, sock = safe.pcall(function () return conn:take_socket() end)
	if not ok or sock == nil then return false, sock or 'take_socket_failed' end

	-- This is the abort boundary for daurnimator/lua-http HTTP/1 streams.  Do
	-- not call stream:shutdown(), connection:shutdown(), or connection:close()
	-- here: those are graceful protocol operations and may wait in cqueues.
	-- Once the socket is taken, direct socket close is the immediate fd teardown
	-- primitive.
	call('close', sock)
	return true, nil
end

local function take_and_close_socket(obj)
	local conn = get_field(obj, 'connection')
	local ok, err = take_and_close_socket_from_connection(conn)
	if ok then return true, nil end

	if obj and type(obj.connection) == 'function' then
		local cok, c = safe.pcall(function () return obj:connection() end)
		if cok and c then
			ok, err = take_and_close_socket_from_connection(c)
			if ok then return true, nil end
		end
	end

	return false, err or 'connection_socket_unavailable'
end

function M.terminate_stream(stream, reason)
	if not stream then return true end
	local ok = call('terminate', stream, reason or 'terminated')
	if ok then return true end
	-- Real lua-http response streams expose stream.connection.  Abort/finaliser
	-- paths must tear down that transport, not fall back to graceful stream close.
	take_and_close_socket(stream)
	return true
end

function M.terminate_server(server, reason)
	if not server then return true end
	local ok = call('terminate', server, reason or 'terminated')
	if ok then return true end
	-- lua-http server objects expose close() as their listener teardown primitive.
	-- This is not a stream/connection graceful close_op path.
	call('close', server)
	return true
end

function M.terminate_websocket(ws, reason)
	if not ws then return true end
	local ok = call('terminate', ws, reason or 'terminated')
	if ok then return true end
	ok = take_and_close_socket(ws)
	if ok then return true end
	-- If the websocket object does not expose its connection, use an abnormal
	-- close with zero timeout as the narrow transport-level teardown primitive.
	call('close', ws, 1006, reason or 'terminated', 0)
	return true
end

function M.terminate_request(req, reason)
	if not req then return true end
	local ok = call('terminate', req, reason or 'terminated')
	if ok then return true end
	ok = take_and_close_socket(req)
	if ok then return true end
	-- lua-http requests do not always expose a connection before req:go() has
	-- produced a stream.  cancel(), when present, is the request-level abort hook.
	call('cancel', req, reason or 'terminated')
	return true
end

return M
