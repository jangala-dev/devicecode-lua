-- services/hal/drivers/wired.lua
-- Thin semantic driver facade around wired-provider backends.

local provider_loader = require 'services.hal.backends.wired.provider'

local M = {}
local Driver = {}
Driver.__index = Driver

function M.new(config, opts)
	local provider, err = provider_loader.new(config or {}, opts or {})
	if not provider then return nil, err end
	return setmetatable({ provider = provider }, Driver), nil
end

function Driver:snapshot_op(req) return self.provider:snapshot_op(req) end
function Driver:watch_op(req) return self.provider:watch_op(req) end
function Driver:apply_attachments_op(req) return self.provider:apply_attachments_op(req) end
function Driver:set_poe_op(req) return self.provider:set_poe_op(req) end
function Driver:bounce_op(req) return self.provider:bounce_op(req) end

function Driver:terminate(reason)
	if self.provider and type(self.provider.terminate) == 'function' then return self.provider:terminate(reason) end
	return true, nil
end

return M
