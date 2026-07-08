-- services/net/drift.lua
-- Pure desired-vs-observed drift calculation for NET.

local tablex = require 'shared.table'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

local function add(items, domain, kind, id, fields)
	local rec = {
		domain = domain,
		kind = kind,
		id = id,
		severity = (fields and fields.severity) or 'warn',
	}
	if fields then
		for k, v in pairs(fields) do
			if k ~= 'severity' then rec[k] = v end
		end
	end
	items[#items + 1] = rec
end

local function observed_by_id(observed, key)
	local t = observed and observed[key] or nil
	return type(t) == 'table' and t or {}
end

local function desired_segment_for_interface(iface)
	if type(iface) ~= 'table' then return nil end
	return iface.segment or (type(iface.segments) == 'table' and iface.segments[1]) or nil
end

local function check_interfaces(items, snapshot, observed)
	local desired = snapshot.interfaces or {}
	local obs = observed_by_id(observed, 'interfaces')
	for id, iface in pairs(desired) do
		if iface.enabled ~= false and obs[id] == nil then
			add(items, 'interfaces', 'missing_interface', id, { severity = 'error', desired = copy(iface) })
		end
	end
	for id, rec in pairs(obs) do
		local iface = desired[id]
		if iface == nil then
			add(items, 'interfaces', 'unexpected_interface', id, { observed = copy(rec) })
		elseif iface.enabled ~= false and rec.enabled == false then
			add(items, 'interfaces', 'interface_disabled', id, { severity = 'error', desired = copy(iface), observed = copy(rec) })
		end
	end
end

local function check_segments(items, snapshot, observed)
	local desired = snapshot.segments or {}
	local obs = observed_by_id(observed, 'segments')
	for id, seg in pairs(desired) do
		if seg.enabled ~= false and obs[id] == nil then
			add(items, 'segments', 'missing_segment', id, { severity = 'error', desired = copy(seg) })
		end
	end
	for id, rec in pairs(obs) do
		if desired[id] == nil then
			add(items, 'segments', 'unexpected_segment', id, { observed = copy(rec) })
		end
	end
end

local function check_firewall(items, snapshot, observed)
	local zones = snapshot.firewall and snapshot.firewall.zones or {}
	local obs_zones = observed and observed.firewall and observed.firewall.zones or nil
	if type(obs_zones) ~= 'table' then return end
	for id, zone in pairs(zones or {}) do
		if obs_zones[id] == nil then
			add(items, 'firewall', 'missing_zone', id, { severity = 'error', desired = copy(zone) })
		end
	end
	for id, zone in pairs(obs_zones) do
		if zones[id] == nil then add(items, 'firewall', 'unexpected_zone', id, { observed = copy(zone) }) end
	end
end

local function check_wan(items, snapshot, observed)
	local desired = snapshot.wan and snapshot.wan.realised_members or {}
	local obs = observed and observed.wan and observed.wan.members or nil
	if type(obs) ~= 'table' then return end
	for id, member in pairs(desired or {}) do
		if member.enabled ~= false and obs[id] == nil then
			add(items, 'wan', 'missing_member', id, { severity = 'error', desired = copy(member) })
		end
	end
	for id, member in pairs(obs) do
		if desired[id] == nil then add(items, 'wan', 'unexpected_member', id, { observed = copy(member) }) end
	end
end

function M.calculate(snapshot, opts)
	opts = opts or {}
	snapshot = snapshot or {}
	local observed = snapshot.observed and snapshot.observed.snapshot or snapshot.observed or {}
	local items = {}
	check_interfaces(items, snapshot, observed)
	check_segments(items, snapshot, observed)
	check_firewall(items, snapshot, observed)
	check_wan(items, snapshot, observed)
	return {
		converged = #items == 0,
		items = items,
		updated_at = opts.now and opts.now() or nil,
	}
end

M._test = { desired_segment_for_interface = desired_segment_for_interface }

return M
