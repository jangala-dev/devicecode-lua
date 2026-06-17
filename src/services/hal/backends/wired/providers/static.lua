-- services/hal/backends/wired/providers/static.lua
-- Static/read-only wired provider, useful for CM5 eth0 and tests.

local op = require 'fibers.op'
local contract = require 'services.hal.backends.wired.contract'
local tablex = require 'shared.table'

local M = {}
local Provider = {}
Provider.__index = Provider

local function copy(v) return tablex.deep_copy(v) end

local CONFIG_FIELDS = {
	provider = true,
	mode = true,
	surfaces = true,
	topology = true,
	meta = true,
	poll_interval_s = true,
}

local function check_allowed_config(config)
	for k in pairs(config or {}) do
		if not CONFIG_FIELDS[k] then return nil, 'unsupported static wired config field: ' .. tostring(k) end
	end
	return true, nil
end

function M.new(config, opts)
	config = config or {}
	opts = opts or {}
	local allowed, allowed_err = check_allowed_config(config)
	if not allowed then return nil, allowed_err end
	if type(opts.provider_id) ~= 'string' or opts.provider_id == '' then return nil, 'opts.provider_id is required' end
	if type(config.surfaces) ~= 'table' then return nil, 'static wired provider requires surfaces' end
	return setmetatable({
		id = opts.provider_id,
		mode = config.mode or 'read_only',
		surfaces = copy(config.surfaces),
		topology = copy(config.topology or {}),
		meta = copy(config.meta or {}),
	}, Provider), nil
end

function Provider:snapshot_op(_req)
	return op.always({
		ok = true,
		provider_id = self.id,
		mode = self.mode,
		writable = false,
		status = { state = 'available', available = true, mode = self.mode },
		surfaces = copy(self.surfaces),
		topology = copy(self.topology),
		meta = copy(self.meta),
	})
end

function Provider:watch_op(req) return self:snapshot_op(req) end
function Provider:apply_attachments_op(_req) return op.always(contract.read_only('apply_attachments')) end
function Provider:set_poe_op(_req) return op.always(contract.read_only('set_poe')) end
function Provider:bounce_op(_req) return op.always(contract.read_only('bounce')) end
function Provider:terminate(_reason) return true end

return M
