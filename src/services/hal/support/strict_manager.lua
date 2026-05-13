-- services/hal/support/strict_manager.lua
--
-- Small shared helpers for callback-free HAL managers exposing the strict
-- op-only manager surface.

local op       = require 'fibers.op'
local resource = require 'devicecode.support.resource'

local M = {}

function M.api_table(extra)
	local out = { api_mode = 'op_only' }
	for k, v in pairs(extra or {}) do out[k] = v end
	return out
end

function M.terminate_drivers(drivers, reason, label)
	for _, driver in pairs(drivers or {}) do
		resource.terminate_checked(driver, reason or 'manager finalised', label or 'HAL manager driver cleanup failed')
	end
	return true, nil
end

function M.fault_op_for_state(state)
	if state and state.scope and state.started then
		return state.scope:fault_op()
	end
	return op.never()
end

function M.finaliser(state, generation, opts)
	opts = opts or {}
	return function (scope)
		if state.scope ~= scope or state.generation ~= generation then return end
		M.terminate_drivers(state.drivers, opts.reason or 'manager finalised', opts.label)
		state.started = false
		state.scope = nil
		state.logger = nil
		state.dev_ev_ch = nil
		state.cap_emit_ch = nil
		state.cfg_ch = nil
		state.drivers = {}
	end
end

return M
