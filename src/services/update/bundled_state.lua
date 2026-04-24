-- services/update/bundled_state.lua
--
-- Durable desired-state record for bundled component updates.  This is kept
-- separate from update jobs: jobs are attempts; this record is the long-lived
-- desired bundled MCU state for the current CM5 release.

local cap_sdk = require 'services.hal.sdk.cap'

local M = {}
local Store = {}
Store.__index = Store

local function copy(v, seen)
	if type(v) ~= 'table' then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, vv in pairs(v) do out[copy(k, seen)] = copy(vv, seen) end
	return out
end

function M.open(store_cap, opts)
	opts = opts or {}
	return setmetatable({
		cap = assert(store_cap, 'store_cap required'),
		namespace = opts.namespace or 'update/state/bundled',
	}, Store)
end

function Store:get(component)
	local opts = assert(cap_sdk.args.new.ControlStoreGetOpts(self.namespace, component))
	local reply, err = self.cap:call_control('get', opts)
	if not reply then return nil, err end
	if reply.ok ~= true then
		if reply.reason == 'not_found' then return nil, nil end
		return nil, reply.reason
	end
	return reply.reason, nil
end

function Store:put(component, value)
	local opts = assert(cap_sdk.args.new.ControlStorePutOpts(self.namespace, component, copy(value)))
	local reply, err = self.cap:call_control('put', opts)
	if not reply then return nil, err end
	if reply.ok ~= true then return nil, reply.reason end
	return true, nil
end

return M
