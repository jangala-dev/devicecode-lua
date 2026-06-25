-- services/hal/drivers/wired.lua
-- Thin semantic driver facade around wired-provider backends.

local provider_loader = require 'services.hal.backends.wired.provider'

local M = {}
local Driver = {}
Driver.__index = Driver

local REQUIRED_BACKEND_OPS = {
	'snapshot_op',
	'watch_op',
	'observe_groups_op',
	'apply_attachments_op',
	'set_poe_op',
	'bounce_op',
}

local function validate_backend(backend, provider_name)
	for _, opname in ipairs(REQUIRED_BACKEND_OPS) do
		if type(backend[opname]) ~= 'function' then
			return nil, ('wired provider %s missing required %s'):format(tostring(provider_name), opname)
		end
	end
	return true, nil
end

function M.new(config, opts)
	opts = opts or {}
	local backend, err, provider_name = provider_loader.new(config or {}, opts)
	if not backend then return nil, err end
	local ok, verr = validate_backend(backend, provider_name)
	if not ok then
		if type(backend.terminate) == 'function' then backend:terminate('invalid backend') end
		return nil, verr
	end
	return setmetatable({
		backend = backend,
		provider_name = provider_name,
		provider_id = opts.provider_id,
	}, Driver), nil
end

function Driver:snapshot_op(req) return self.backend:snapshot_op(req) end
function Driver:watch_op(req) return self.backend:watch_op(req) end
function Driver:observe_groups_op(req) return self.backend:observe_groups_op(req) end
function Driver:apply_attachments_op(req) return self.backend:apply_attachments_op(req) end
function Driver:set_poe_op(req) return self.backend:set_poe_op(req) end
function Driver:bounce_op(req) return self.backend:bounce_op(req) end

function Driver:terminate(reason)
	if self.backend and type(self.backend.terminate) == 'function' then return self.backend:terminate(reason) end
	return true, nil
end

return M
