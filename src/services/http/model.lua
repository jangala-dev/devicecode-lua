-- services/http/model.lua
-- Pulse-backed HTTP service model.

local base_model = require 'devicecode.support.model'
local tablex     = require 'shared.table'

local M = {}

local function equals(a, b)
	for k, v in pairs(a or {}) do if (b or {})[k] ~= v then return false end end
	for k in pairs(b or {}) do if (a or {})[k] == nil then return false end end
	return true
end

function M.initial()
	return {
		state = 'starting',
		backend = 'starting',
		ready = false,
		active_listeners = 0,
		active_contexts = 0,
		active_exchanges = 0,
		active_websockets = 0,
		completed_exchanges = 0,
		failed_exchanges = 0,
		rejected_requests = 0,
		tracked_requests = 0,
		tracked_operations = 0,
		tracked_contexts = 0,
		tracked_listeners = 0,
		tracked_exchanges = 0,
		tracked_websockets = 0,
		last_error = nil,
		policy_generation = 1,
	}
end

function M.new(initial)
	return base_model.new(initial or M.initial(), {
		copy = tablex.shallow_copy,
		equals = equals,
		label = 'http.model',
	})
end

return M
