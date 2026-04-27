-- services/update/backends/cm5_swupdate.lua
--
-- CM5 update backend.
--
-- This is a small policy adapter over the generic component proxy backend:
--   * transport/control is delegated to component_proxy
--   * this file supplies CM5-specific reconcile policy only

local reconcile = require 'services.update.backends.component_reconcile'

local M = {}

local function reconcile_component(component_state, job)
	return reconcile.evaluate_component_state(component_state, job, {
		require_boot_change = false,
	})
end

function M.new(opts)
	opts = opts or {}
	local proxy = assert(opts.proxy_mod, 'proxy_mod required')

	return proxy.new({
		component = opts.component or 'cm5',
		artifact_retention = 'keep',
		timeout_prepare = opts.timeout_prepare or 10.0,
		timeout_stage = opts.timeout_stage or 30.0,
		timeout_commit = opts.timeout_commit or 10.0,
		reconcile = reconcile_component,
	})
end

return M
