-- services/hal/util.lua
--
-- Small helpers shared by the HAL service.

local safe = require 'coxpcall'

local M = {}

function M.safe_invoke(backend, method, arg1, msg)
	local fn = backend and backend[method]
	if type(fn) ~= 'function' then
		return { ok = false, err = 'unknown method: ' .. tostring(method) }
	end

	local ok, out = safe.pcall(function()
		return fn(backend, arg1, msg)
	end)

	if not ok then
		return { ok = false, err = tostring(out) }
	end

	if type(out) ~= 'table' then
		return { ok = false, err = 'backend returned non-table reply' }
	end

	if out.ok == nil then out.ok = true end
	return out
end

function M.reply_best_effort(conn, msg, payload)
	if msg.reply_to == nil then
		return false, 'no_reply_to'
	end
	local ok, reason = conn:publish_one(msg.reply_to, payload, { id = msg.id })
	return ok, reason
end

function M.try_enqueue(tx, job)
	local ok, reason = tx:send(job)
	if ok == true then return true, nil end
	if ok == nil then return false, 'closed' end
	return false, reason or 'full'
end

return M
