-- services/net/intent_realiser.lua
-- Turns product-level NET intent plus observed source facts into apply intent.

local tablex = require 'shared.table'

local M = {}

local function copy(v) return tablex.deep_copy(v) end
local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function gsm_ifname(sources, role)
	local rec = sources and sources.gsm_uplinks and sources.gsm_uplinks[role]
	if type(rec) ~= 'table' then return nil end
	local linux = type(rec.linux) == 'table' and rec.linux or {}
	local ifname = linux.ifname
	if type(ifname) == 'string' and ifname ~= '' then return ifname end
	return nil
end

local function merge_ipv4(existing, metric)
	local out = copy(existing or {})
	out.mode = out.mode or out.proto or 'dhcp'
	out.proto = nil
	out.peerdns = out.peerdns ~= nil and out.peerdns or false
	out.metric = metric
	return out
end

local function set_route_metric_on_interface(intent, iface_id, metric)
	local iface = intent.interfaces and intent.interfaces[iface_id]
	if type(iface) ~= 'table' then return false end
	iface.addressing = type(iface.addressing) == 'table' and iface.addressing or {}
	iface.addressing.ipv4 = merge_ipv4(iface.addressing.ipv4, metric)
	return true
end

local function set_route_metric_on_segment(intent, seg_id, metric)
	local seg = intent.segments and intent.segments[seg_id]
	if type(seg) ~= 'table' then return false end
	seg.addressing = type(seg.addressing) == 'table' and seg.addressing or {}
	seg.addressing.ipv4 = merge_ipv4(seg.addressing.ipv4, metric)
	return true
end

local function realisable_static_member(intent, iface_id)
	return (intent.interfaces and intent.interfaces[iface_id] ~= nil)
		or (intent.segments and intent.segments[iface_id] ~= nil)
end

function M.realise(base_intent, sources, opts)
	opts = opts or {}
	local intent = copy(base_intent or {})
	intent.interfaces = intent.interfaces or {}
	intent.wan = intent.wan or {}
	intent.wan.members = intent.wan.members or {}

	local realised_members = {}
	for index, member_id in ipairs(sorted_keys(intent.wan.members)) do
		local member = intent.wan.members[member_id]
		if type(member) == 'table' and member.enabled ~= false and member.disabled ~= true then
			local iface_id = member.interface or member_id
			member.interface = iface_id
			local route_metric = tonumber(member.route_metric) or (10 + index)
			member.route_metric = route_metric
			member.metric = tonumber(member.metric) or 1
			-- HAL/OpenWrt still consumes this backend-shaped alias when realising mwan3.
			member.mwan_metric = member.metric
			local src = member.source
			if type(src) == 'table' and src.kind == 'gsm-uplink' then
				local ifname = gsm_ifname(sources or {}, src.id)
				if ifname then
					intent.interfaces[iface_id] = {
						kind = 'direct',
						role = 'wan',
						enabled = true,
						endpoint = { ifname = ifname },
						addressing = { ipv4 = { mode = 'dhcp', peerdns = false, metric = route_metric } },
						firewall = { zone = 'wan' },
						dhcp = { enabled = false },
						source = { kind = 'gsm-uplink', id = src.id },
					}
					realised_members[member_id] = member
				end
			elseif realisable_static_member(intent, iface_id) then
				if not set_route_metric_on_interface(intent, iface_id, route_metric) then
					set_route_metric_on_segment(intent, iface_id, route_metric)
				end
				realised_members[member_id] = member
			elseif opts.keep_unrealised == true then
				realised_members[member_id] = member
			end
		end
	end
	intent.wan.members = realised_members
	return intent
end

function M.realised_fingerprint(intent, sources)
	local realised = M.realise(intent, sources or {})
	local parts = {}
	for _, id in ipairs(sorted_keys(realised.wan and realised.wan.members)) do
		local m = realised.wan.members[id]
		local iface = m and m.interface or id
		local i = realised.interfaces and realised.interfaces[iface] or nil
		local ep = type(i) == 'table' and type(i.endpoint) == 'table' and i.endpoint or {}
		parts[#parts + 1] = table.concat({ tostring(id), tostring(iface), tostring(ep.ifname), tostring(m and m.route_metric), tostring(m and m.metric) }, ':')
	end
	return table.concat(parts, '|')
end

return M
