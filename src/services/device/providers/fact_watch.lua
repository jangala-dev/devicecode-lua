-- services/device/providers/fact_watch.lua
--
-- Generic fact/event device provider.
-- Retained fact watching, event subscription and staleness handling now live
-- in services.device.observe; this provider remains the default named adapter
-- for existing component configs.

local observe = require 'services.device.observe'

local M = {}

function M.run(ctx)
	return observe.run(ctx)
end

return M
