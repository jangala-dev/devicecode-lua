-- services/hal/backends/wired/providers/rtl8380m_http.lua
--
-- Phase 1 stub for the pre-devicecode RTL8380M switch-fabric driver.
--
-- This provider is deliberately telemetry-only.  It defines the API the real
-- manufacturer-firmware HTTP driver must implement, without baking HTTP details
-- into Wired, Device or Net.
--
-- Expected real-driver implementation:
--   * fetch_snapshot_op(req) must perform the HTTP request(s) and return:
--       {
--         ok = true,
--         provider_id = "switch-main",
--         mode = "read_only",          -- Phase 1; "writable" in Phase 2
--         writable = false,
--         status = { state="available", available=true, ... },
--         surfaces = {
--           ["port-1"] = {
--             provider_surface_id = "port-1",
--             kind = "ethernet-port",
--             link = { state="up", speed_mbps=1000, duplex="full" },
--             attachment = { mode="access", vlan=100 },
--             poe = { state="off"|"delivering"|"fault", watts=0 },
--           },
--           ["uplink-cm5"] = {
--             provider_surface_id = "uplink-cm5",
--             kind = "switch-port",
--             link = { state="up", speed_mbps=1000 },
--             attachment = { mode="trunk", vlans={10,11,12,100,101} },
--           },
--         },
--         topology = { ... provider-observed topology, semantic not HTTP-shaped ... },
--       }
--   * Phase 1 control methods must return read_only.
--   * Phase 2 should implement apply_attachments_op/set_poe_op/bounce_op with
--     the same semantic request/response shape; no caller above HAL should know
--     manufacturer URL paths, session cookies, page forms or register names.

local op = require 'fibers.op'
local contract = require 'services.hal.backends.wired.contract'
local tablex = require 'shared.table'

local M = {}
local Provider = {}
Provider.__index = Provider

local function copy(v) return tablex.deep_copy(v) end

local function default_surfaces()
	return {
		['uplink-cm5'] = {
			provider_surface_id = 'uplink-cm5',
			kind = 'switch-port',
			capabilities = { trunk = true, access = false, poe = false },
			link = { state = 'unknown' },
			attachment = { mode = 'trunk', vlans = {} },
		},
	}
end

function M.new(config, opts)
	config = config or {}
	return setmetatable({
		id = config.id or config.capability_id or 'switch-main',
		base_url = config.base_url or config.url,
		mode = config.mode or 'read_only',
		telemetry = copy(config.telemetry or {}),
		surfaces = copy(config.surfaces or default_surfaces()),
		topology = copy(config.topology or {}),
		logger = opts and opts.logger,
	}, Provider), nil
end

function Provider:fetch_snapshot_op(_req)
	-- Stub.  The real driver should replace this method with HTTP-backed work.
	return op.always({
		ok = true,
		provider_id = self.id,
		mode = self.mode,
		writable = false,
		status = {
			state = 'available',
			available = true,
			mode = self.mode,
			driver = 'rtl8380m_http',
			stub = true,
			base_url_configured = self.base_url ~= nil,
		},
		surfaces = copy(self.surfaces),
		topology = copy(self.topology),
		telemetry = copy(self.telemetry),
	})
end

function Provider:snapshot_op(req) return self:fetch_snapshot_op(req) end
function Provider:watch_op(req) return self:fetch_snapshot_op(req) end
function Provider:apply_attachments_op(_req) return op.always(contract.read_only('apply_attachments')) end
function Provider:set_poe_op(_req) return op.always(contract.read_only('set_poe')) end
function Provider:bounce_op(_req) return op.always(contract.read_only('bounce')) end
function Provider:terminate(_reason) return true end

return M
