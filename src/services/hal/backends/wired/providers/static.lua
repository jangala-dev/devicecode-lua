-- services/hal/backends/wired/providers/static.lua
-- Static/read-only wired provider, useful for CM5 eth0 and tests.

local op = require 'fibers.op'
local contract = require 'services.hal.backends.wired.contract'
local tablex = require 'shared.table'

local M = {}
local Provider = {}
Provider.__index = Provider

local function copy(v) return tablex.deep_copy(v) end

function M.new(config, _opts)
	config = config or {}
	return setmetatable({
		id = config.id or config.capability_id or 'cm5-local-wired',
		mode = config.mode or 'read_only',
		surfaces = copy(config.surfaces or {
			eth0 = { provider_surface_id = 'eth0', kind = 'direct-nic', link = { state = 'unknown' } },
		}),
		topology = copy(config.topology or {}),
		meta = copy(config.meta or config.metadata or {}),
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
