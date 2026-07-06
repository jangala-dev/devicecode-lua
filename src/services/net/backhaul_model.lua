-- services/net/backhaul_model.lua
--
-- Pure reducer from HAL-observed host facts and GSM uplink sources into NET's
-- product-level backhaul semantics.  OpenWrt/mwan3 vocabulary is confined to
-- HAL-observed provenance; policy and UI should consume the semantic fields in
-- this model.

local tablex = require 'shared.table'

local M = {}
local copy = tablex.deep_copy

local function is_table(v) return type(v) == 'table' end

local function observed_multiwan(snapshot)
	local observed = snapshot and snapshot.observed or nil
	local mw = observed and observed.snapshot and observed.snapshot.multiwan or nil
	if not is_table(mw) then mw = observed and observed.multiwan or nil end
	return is_table(mw) and mw or nil
end

local function status_by_interface(snapshot, iface)
	if type(iface) ~= 'string' or iface == '' then return nil end
	local mw = observed_multiwan(snapshot)
	if not mw then return nil end
	local by_sem = mw.interfaces_by_semantic
	if is_table(by_sem) and is_table(by_sem[iface]) then return by_sem[iface] end
	local ifaces = mw.interfaces
	if is_table(ifaces) and is_table(ifaces[iface]) then return ifaces[iface] end
	return nil
end

local function semantic_state_from_host(st)
	if not is_table(st) then return 'unknown', false end
	local state = tostring(st.state or st.status or ''):lower()
	if state == '' then
		if st.usable == true or st.online == true then state = 'online'
		elseif st.enabled == false then state = 'disabled'
		else state = 'unknown' end
	end
	local usable = st.usable == true or state == 'online'
	if state == 'up' or state == 'connected' then state = 'online'; usable = true end
	if state ~= 'online' then usable = false end
	return state, usable
end

local function member_interface(member, uplink_id)
	member = member or {}
	return member.interface or uplink_id
end

local function member_metric(member)
	return tonumber(member and member.metric) or 1
end

local function gsm_source(member)
	local src = member and member.source or nil
	if is_table(src) and src.kind == 'gsm-uplink' then return src.id end
	return nil
end

local function gsm_uplink(snapshot, member)
	local id = gsm_source(member)
	if not id then return nil end
	return snapshot and snapshot.sources and snapshot.sources.gsm_uplinks and snapshot.sources.gsm_uplinks[id] or nil
end

local function reduce_gsm(snapshot, uplink_id, member, opts)
	local gsm = gsm_uplink(snapshot, member)
	local state = 'unknown'
	local usable = false
	if is_table(gsm) then
		state = tostring(gsm.state or (gsm.connected and 'connected' or 'disconnected'))
		if state == 'connected' then state = 'online' end
		usable = gsm.connected == true and state == 'online'
	end
	local linux = is_table(gsm and gsm.linux) and gsm.linux or {}
	return {
		id = tostring(uplink_id),
		role = member.role or uplink_id,
		interface = member_interface(member, uplink_id),
		ifname = linux.ifname or member.device or member.ifname,
		state = state,
		usable = usable,
		metric = member_metric(member),
		source = { kind = 'gsm-uplink', id = gsm_source(member) },
		observed_at = is_table(gsm) and (gsm.updated_at or gsm.observed_at) or (opts and opts.now),
	}
end

local function reduce_host(snapshot, uplink_id, member, opts)
	local iface = member_interface(member, uplink_id)
	local st = status_by_interface(snapshot, iface)
	local mw = observed_multiwan(snapshot) or {}
	local state, usable = semantic_state_from_host(st)
	return {
		id = tostring(uplink_id),
		role = member.role or uplink_id,
		interface = iface,
		ifname = st and st.ifname or member.device or member.ifname,
		state = state,
		usable = usable,
		observed = st ~= nil,
		metric = member_metric(member),
		uptime_s = st and (tonumber(st.uptime_s) or tonumber(st.uptime)) or nil,
		age_s = st and (tonumber(st.age_s) or tonumber(st.age)) or nil,
		source = {
			kind = 'host-multiwan',
			backend = st and (st.backend or mw.backend) or nil,
			tool = st and (st.tool or mw.source) or nil,
		},
		probes = st and copy(st.probes) or nil,
		observed_at = st and (st.observed_at or mw.observed_at) or nil,
	}
end

function M.reduce(snapshot, opts)
	opts = opts or {}
	local out = {
		schema = 'devicecode.net.backhaul/1',
		state = 'unknown',
		observed_at = opts.now,
		uplinks = {},
	}
	local members = snapshot and snapshot.wan and snapshot.wan.members or {}
	local total, online, known = 0, 0, 0
	for uplink_id, member in pairs(members or {}) do
		if is_table(member) and member.enabled ~= false and member.disabled ~= true then
			local rec
			if gsm_source(member) then rec = reduce_gsm(snapshot, uplink_id, member, opts)
			else rec = reduce_host(snapshot, uplink_id, member, opts) end
			out.uplinks[tostring(uplink_id)] = rec
			total = total + 1
			if rec.state ~= 'unknown' then known = known + 1 end
			if rec.usable == true and rec.state == 'online' then online = online + 1 end
		end
	end
	if total == 0 then out.state = 'not_configured'
	elseif known == 0 then out.state = 'unknown'
	elseif online == total then out.state = 'ok'
	elseif online > 0 then out.state = 'degraded'
	else out.state = 'down' end
	out.total = total
	out.online = online
	return out
end

M._test = {
	observed_multiwan = observed_multiwan,
	status_by_interface = status_by_interface,
}

return M
