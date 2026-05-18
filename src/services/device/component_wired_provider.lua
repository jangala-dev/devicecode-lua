-- services/device/component_wired_provider.lua
-- Generic Device component composition for appliance wired-provider capabilities.
--
-- This is used for both local providers (for example the CM5 direct NIC) and
-- provider-backed switch fabrics. Device curates raw host/member facts into the
-- public cap/wired-provider/<id>/... surface consumed by services.wired.

local model = require 'services.device.model'
local tablex = require 'shared.table'

local M = { kind = 'wired-provider' }

local function copy(v) return model.copy_value(v) end
local function table_or_empty(v) return tablex.table_or_empty(v) end
local function first_non_nil(...)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if v ~= nil then return v end
	end
	return nil
end

function M.normalise_fact(fact, raw)
	if fact == 'wired_provider_status' or fact == 'wired_provider_surfaces' or fact == 'wired_provider_topology' then
		return copy(raw or {}), nil
	end
	return copy(raw), nil
end

function M.normalise_event(_, raw)
	return copy(raw), nil
end

function M.compose(raw_facts)
	raw_facts = table_or_empty(raw_facts)
	local status = table_or_empty(raw_facts.wired_provider_status)
	local surfaces_payload = table_or_empty(raw_facts.wired_provider_surfaces)
	local surfaces = surfaces_payload.surfaces or surfaces_payload
	local topology = table_or_empty(raw_facts.wired_provider_topology)
	return {
		health = {
			health = (status.available == false) and 'degraded' or 'ok',
			fault = status.err or status.reason,
			details = copy(status),
		},
		wired_provider = {
			status = copy(status),
			surfaces = copy(surfaces or {}),
			topology = copy(topology or {}),
		},
		runtime = {
			provider_mode = status.mode,
			driver = status.driver,
		},
	}
end

function M.availability(base, rec)
	local out = copy(base)
	local facts = table_or_empty(rec and rec.raw_facts)
	local status = table_or_empty(facts.wired_provider_status)
	local state = first_non_nil(status.state, status.availability)
	if status.available == false or state == 'not_configured' or state == 'unavailable' then
		out.availability = 'degraded'
		out.health = 'warning'
		out.reason = status.reason or status.err or state or 'wired_provider_unavailable'
	elseif status.available == true or state == 'available' then
		out.availability = 'available'
		out.health = 'ok'
		out.reason = nil
	end
	return out
end

return M
