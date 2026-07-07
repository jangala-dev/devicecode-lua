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

local function observed_live(snapshot)
	local observed = snapshot and snapshot.observed or nil
	local live = observed and observed.snapshot and observed.snapshot.live or nil
	if not is_table(live) then live = observed and observed.live or nil end
	return is_table(live) and live or nil
end

local function live_interface(snapshot, iface, ifname)
	local live = observed_live(snapshot)
	local interfaces = live and live.interfaces or nil
	if not is_table(interfaces) then return nil end
	if type(iface) == 'string' and iface ~= '' and is_table(interfaces[iface]) then return interfaces[iface] end
	if type(ifname) == 'string' and ifname ~= '' and is_table(interfaces[ifname]) then return interfaces[ifname] end
	return nil
end

local function valid_address(addr)
	if type(addr) ~= 'string' or addr == '' then return nil end
	if addr == '0.0.0.0' or addr == '::' then return nil end
	return addr
end

local function first_address(list)
	if not is_table(list) then return nil end
	for i = 1, #list do
		local rec = list[i]
		local addr = is_table(rec) and valid_address(rec.address or rec.ip or rec.addr) or valid_address(rec)
		if addr then return addr end
	end
	return nil
end

local function select_path_address(st, source)
	if not is_table(st) then return nil end
	local ipv4 = first_address(st.ipv4 or st.addresses_ipv4 or st.address)
		or valid_address(st.ipv4_address or st.ipaddr or st.ip or st.address)
	if ipv4 then return { family = 'ipv4', address = ipv4, source = source } end
	local ipv6 = first_address(st.ipv6 or st.addresses_ipv6 or st['ipv6-address'] or st.ipv6_address)
		or valid_address(st.ipv6addr or st.ip6addr)
	if ipv6 then return { family = 'ipv6', address = ipv6, source = source } end
	return nil
end

local function path_address(snapshot, iface, ifname, st)
	return select_path_address(live_interface(snapshot, iface, ifname), 'hal-network-live')
		or select_path_address(st, 'multiwan-status')
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

local function interface_endpoint(snapshot, iface)
	local rec = snapshot and snapshot.interfaces and snapshot.interfaces[iface] or nil
	return is_table(rec) and is_table(rec.endpoint) and rec.endpoint or {}
end

local function member_interface(member, uplink_id)
	member = member or {}
	return member.interface or uplink_id
end

local function member_metric(member)
	return tonumber(member and member.metric) or 1
end

local function vlan_id(vlan)
	if type(vlan) == 'number' then return vlan end
	if is_table(vlan) then return tonumber(vlan.id) end
	return nil
end

local function first_kind(segment, endpoint)
	local kind = (is_table(segment) and segment.kind) or (is_table(endpoint) and endpoint.kind)
	if kind == 'wan' or kind == 'wired' then return 'wired' end
	return kind or 'wired'
end

local function link_view(snapshot, iface, member, source_kind)
	local segment = snapshot and snapshot.segments and snapshot.segments[iface] or nil
	local endpoint = interface_endpoint(snapshot, iface)
	local vid = vlan_id(member and member.vlan) or vlan_id(segment and segment.vlan) or vlan_id(endpoint and endpoint.vlan)
	local kind = source_kind == 'gsm-uplink' and 'cellular' or first_kind(segment, endpoint)
	return {
		kind = kind,
		segment = iface,
		vlan = vid,
	}
end

local function status_source(snapshot, st)
	local mw = observed_multiwan(snapshot) or {}
	return {
		kind = 'host-multiwan',
		backend = st and (st.backend or mw.backend) or mw.backend,
		tool = st and (st.tool or mw.source) or mw.source,
	}
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
	local linux = is_table(gsm and gsm.linux) and gsm.linux or {}
	local iface = member_interface(member, uplink_id)
	local st = status_by_interface(snapshot, iface)
	local state, usable = semantic_state_from_host(st)
	local endpoint = interface_endpoint(snapshot, iface)
	local ifname = st and st.ifname or linux.ifname or member.device or member.ifname or endpoint.ifname or endpoint.device or endpoint.name
	return {
		id = tostring(uplink_id),
		role = member.role or uplink_id,
		interface = iface,
		ifname = ifname,
		state = state,
		usable = usable,
		observed = st ~= nil,
		metric = member_metric(member),
		path_address = path_address(snapshot, iface, ifname, st),
		source = { kind = 'gsm-uplink', id = gsm_source(member) },
		status_source = status_source(snapshot, st),
		link = link_view(snapshot, iface, member, 'gsm-uplink'),
		observed_at = st and (st.observed_at or ((observed_multiwan(snapshot) or {}).observed_at))
			or (is_table(gsm) and (gsm.updated_at or gsm.observed_at) or (opts and opts.now)),
	}
end

local function reduce_host(snapshot, uplink_id, member, opts)
	local iface = member_interface(member, uplink_id)
	local st = status_by_interface(snapshot, iface)
	local state, usable = semantic_state_from_host(st)
	local endpoint = interface_endpoint(snapshot, iface)
	local ifname = st and st.ifname or member.device or member.ifname or endpoint.ifname or endpoint.device or endpoint.name
	return {
		id = tostring(uplink_id),
		role = member.role or uplink_id,
		interface = iface,
		ifname = ifname,
		state = state,
		usable = usable,
		observed = st ~= nil,
		metric = member_metric(member),
		path_address = path_address(snapshot, iface, ifname, st),
		uptime_s = st and (tonumber(st.uptime_s) or tonumber(st.uptime)) or nil,
		age_s = st and (tonumber(st.age_s) or tonumber(st.age)) or nil,
		source = status_source(snapshot, st),
		status_source = status_source(snapshot, st),
		link = link_view(snapshot, iface, member, 'host-multiwan'),
		probes = st and copy(st.probes) or nil,
		observed_at = st and (st.observed_at or ((observed_multiwan(snapshot) or {}).observed_at)) or (opts and opts.now),
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
	local members = snapshot and snapshot.wan and snapshot.wan.configured_members or {}
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
	select_path_address = select_path_address,
}

return M
