-- services/net/capability_resolver.lua
-- Default NET -> HAL capability resolution.
--
-- This is a service component, not a compatibility shim.  Production NET uses
-- the curated public HAL capability surface by default; tests may still inject
-- concrete refs through opts.

local cap_sdk = require 'services.hal.sdk.cap'
local bus_cleanup = require 'devicecode.support.bus_cleanup'

local M = {}
local Resolver = {}
Resolver.__index = Resolver

local DEFAULT_ID = 'main'

local CAP_SPECS = {
	{ key = 'network_config', class = 'network-config', opt = 'network_config_cap' },
	{ key = 'network_state', class = 'network-state', opt = 'network_state_cap' },
	{ key = 'network_diagnostics', class = 'network-diagnostics', opt = 'network_diagnostics_cap' },
}

local function ref_for(conn, opts, spec)
	if opts and opts[spec.opt] ~= nil then return opts[spec.opt] end
	if opts and opts.resolve_defaults == false then return nil end
	if not conn then return nil end
	local id = opts and (opts[spec.key .. '_id'] or opts.cap_id) or nil
	return cap_sdk.new_curated_cap_ref(conn, spec.class, id or DEFAULT_ID)
end

local function status_sub_for(conn, ref, opts, spec)
	if not conn or not ref or type(ref.get_status_sub) ~= 'function' then return nil end
	if opts and opts.watch_status == false then return nil end
	return ref:get_status_sub({
		queue_len = opts and opts.status_queue_len or 8,
		full = opts and opts.status_full or 'drop_oldest',
	})
end

function M.open(conn, opts)
	opts = opts or {}
	local refs = {}
	local subs = {}
	local status = {}

	for i = 1, #CAP_SPECS do
		local spec = CAP_SPECS[i]
		local ref = ref_for(conn, opts, spec)
		refs[spec.key] = ref
		status[spec.key] = ref and 'configured' or 'not_configured'
		local sub, err = status_sub_for(conn, ref, opts, spec)
		if sub then
			subs[spec.key] = sub
		elseif err then
			status[spec.key] = 'status_unavailable'
		end
	end

	return setmetatable({
		conn = conn,
		refs = refs,
		status_subs = subs,
		status = status,
	}, Resolver), nil
end

function Resolver:client_opts(extra)
	extra = extra or {}
	local out = {}
	for k, v in pairs(extra) do out[k] = v end
	out.network_config_cap = out.network_config_cap or self.refs.network_config
	out.network_state_cap = out.network_state_cap or self.refs.network_state
	out.network_diagnostics_cap = out.network_diagnostics_cap or self.refs.network_diagnostics
	return out
end

function Resolver:status_snapshot()
	local out = {}
	for k, v in pairs(self.status or {}) do out[k] = v end
	return out
end

function Resolver:record_status(name, payload)
	local st = 'unavailable'
	if type(payload) == 'table' then
		if payload.available == true then st = 'available'
		elseif payload.state ~= nil then st = tostring(payload.state)
		end
	elseif payload ~= nil then
		st = tostring(payload)
	end
	self.status[name] = st
	return st
end

function Resolver:close()
	for k, sub in pairs(self.status_subs or {}) do
		bus_cleanup.unsubscribe(self.conn, sub)
		self.status_subs[k] = nil
	end
	return true, nil
end

M.CAP_SPECS = CAP_SPECS

return M
