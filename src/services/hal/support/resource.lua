---@module 'services.hal.support.resource'

-- Uniform bounded cleanup helpers for op-only HAL resources.
--
-- Vocabulary:
--   close_op()      orderly close; may suspend; never use from finalisers
--   close_now()     bounded immediate close; must not suspend
--   abandon_safe    no cleanup is required when ownership is abandoned
--   cancel_safe_io  pending I/O is made harmless by cancellation/shutdown

local M = {}

function M.close_now_best_effort(obj)
	if not obj then
		return true, nil
	end

	if obj.abandon_safe == true then
		return true, nil
	end

	if type(obj.close_now) ~= 'function' then
		return false, 'resource_has_no_close_now'
	end

	local ok, a, b = pcall(function ()
		return obj:close_now()
	end)
	if not ok then
		return false, a
	end
	if a == nil or a == false then
		return false, b or 'close_now_failed'
	end
	return true, nil
end

function M.require_close_now_or_abandon_safe(obj, what)
	if not obj then
		return true, nil
	end

	if obj.abandon_safe == true or type(obj.close_now) == 'function' then
		return true, nil
	end

	return false, (what or 'resource') .. '_has_no_close_now_or_abandon_safe'
end

return M
