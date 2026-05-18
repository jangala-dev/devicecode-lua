-- services/hal/drivers/network.lua
-- Thin semantic driver facade around a network backend provider.

local provider_loader = require 'services.hal.backends.network.provider'

local M = {}
local Driver = {}
Driver.__index = Driver

function M.new(config, opts)
	local provider, err = provider_loader.new(config or {}, opts or {})
	if not provider then return nil, err end
	return setmetatable({ provider = provider }, Driver), nil
end

function Driver:validate_op(req) return self.provider:validate_op(req) end
function Driver:plan_op(req) return self.provider:plan_op(req) end
function Driver:apply_op(req) return self.provider:apply_op(req) end
function Driver:snapshot_op(req) return self.provider:snapshot_op(req) end
function Driver:watch_op(req) return self.provider:watch_op(req) end
function Driver:probe_link_op(req) return self.provider:probe_link_op(req) end
function Driver:read_counters_op(req) return self.provider:read_counters_op(req) end
function Driver:apply_live_weights_op(req) return self.provider:apply_live_weights_op(req) end
function Driver:apply_shaping_op(req) return self.provider:apply_shaping_op(req) end
function Driver:speedtest_op(req) return self.provider:speedtest_op(req) end

function Driver:terminate(reason)
	if self.provider and type(self.provider.terminate) == 'function' then
		return self.provider:terminate(reason)
	end
	return true, nil
end

return M
