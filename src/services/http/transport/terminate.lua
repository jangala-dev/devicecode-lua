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

function M.terminate_stream(stream, reason)
	if not stream then return true end
	local ok = call('shutdown', stream)
	if ok then return true end
	ok = call('close', stream)
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
	local ok = call('shutdown', req)
	if ok then return true end
	ok = call('close', req)
	if ok then return true end
	ok = call('cancel', req, reason or 'terminated')
	if ok then return true end
	return true
end

return M
