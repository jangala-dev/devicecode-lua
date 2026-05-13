-- services/ui/supervision.lua
--
-- Pure supervision policy helpers for UI components.
--
-- These functions classify completed scoped work as data. Coordinators record
-- the completion first, then apply the returned action. No function here may
-- perform Ops or touch transport resources.

local M = {}

local function result(ev)
	return type(ev) == 'table' and type(ev.result) == 'table' and ev.result or {}
end

local function reason_from(ev, fallback)
	local r = result(ev)
	return ev.primary or r.reason or r.err or r.status or ev.status or fallback
end

local function decision(class, action, reason)
	return {
		class = class,
		action = action or 'continue',
		reason = reason,
	}
end


local function component_name(ev)
	return type(ev) == 'table' and ev.component or nil
end

function M.classify_service_component_done(_, ev)
	local component = component_name(ev) or 'component'

	if ev.status == 'ok' then
		return decision('normal_close', 'continue', reason_from(ev, component .. '_stopped'))
	end

	if ev.status == 'failed' then
		return decision('failed', 'fail_service', ('%s failed: %s'):format(component, tostring(reason_from(ev, 'failed'))))
	end

	if ev.status == 'cancelled' then
		return decision('cancelled_unexpected', 'fail_service', ('%s cancelled unexpectedly: %s'):format(component, tostring(reason_from(ev, 'cancelled'))))
	end

	return decision('failed', 'fail_service', ('%s ended with invalid status: %s'):format(component, tostring(ev.status)))
end

M._test = {
	reason_from = reason_from,
}

return M
