-- services/net/wan_policy.lua
-- Pure WAN runtime policy for speedtests and live weights.

local tablex = require 'shared.table'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function flag_enabled(v)
	if v == true then return true end
	if type(v) == 'table' then return v.enabled ~= false end
	return false
end

function M.speedtest_enabled(snapshot)
	local wan = snapshot and snapshot.wan or {}
	local lb = type(wan.load_balancing) == 'table' and wan.load_balancing or {}
	local rt = type(wan.runtime) == 'table' and wan.runtime or {}
	return flag_enabled(lb.speedtest)
		or flag_enabled(lb.speedtests)
		or flag_enabled(rt.speedtest)
		or flag_enabled(rt.speedtests)
end

function M.live_weight_policy(snapshot)
	local wan = snapshot and snapshot.wan or {}
	local lb = type(wan.load_balancing) == 'table' and wan.load_balancing or {}
	local rt = type(wan.runtime) == 'table' and wan.runtime or {}
	return rt.weight_policy or rt.live_weight_policy or lb.weight_policy or lb.policy or wan.policy or 'balanced'
end

local function member_interface(member, uplink_id)
	member = member or {}
	return member.openwrt_interface
		or member.network_interface
		or member.interface
		or member.iface
		or member.link_id
		or uplink_id
end

function M.build_speedtest_request(snapshot, uplink_id, member)
	member = member or {}
	local iface_id = member_interface(member, uplink_id)
	local iface = snapshot.interfaces and snapshot.interfaces[iface_id] or nil
	local endpoint = type(iface) == 'table' and type(iface.endpoint) == 'table' and iface.endpoint or {}
	return {
		interface = iface_id,
		device = member.device or member.linux_interface or member.ifname or endpoint.ifname or endpoint.device or endpoint.name or (iface and iface.device),
		url = member.speedtest_url,
		max_duration_s = member.speedtest_duration_s,
		uplink_id = tostring(uplink_id),
		metric = member.metric or member.priority or 1,
	}
end

function M.collect_uplinks(snapshot)
	local out = {}
	local members = snapshot and snapshot.wan and snapshot.wan.members or {}
	local keys = sorted_keys(members)
	for i = 1, #keys do
		local uplink_id = keys[i]
		local member = members[uplink_id]
		if type(member) == 'table' and member.enabled ~= false and member.disabled ~= true then
			local req = M.build_speedtest_request(snapshot, uplink_id, member)
			if type(req.interface) == 'string' and req.interface ~= '' then
				out[#out + 1] = { uplink_id = tostring(uplink_id), member = copy(member), request = req }
			end
		end
	end
	return out
end

function M.all_speedtests_done(snapshot, generation)
	local uplinks = M.collect_uplinks(snapshot)
	if #uplinks == 0 then return false end
	local tests = snapshot.wan_runtime and snapshot.wan_runtime.speedtests or {}
	for i = 1, #uplinks do
		local id = uplinks[i].uplink_id
		local rec = tests[id]
		if not rec or rec.generation ~= generation or rec.state == 'running' then return false end
	end
	return true
end

function M.compute_weights(snapshot, generation)
	local runtime = snapshot.wan_runtime or {}
	local tests = runtime.speedtests or {}
	local members, total = {}, 0
	local current = {}
	for _, uplink in ipairs(M.collect_uplinks(snapshot)) do current[uplink.uplink_id] = true end

	for uplink_id, rec in pairs(tests) do
		if current[uplink_id] and rec.generation == generation and rec.state == 'done' and rec.ok == true then
			local mbps = tonumber(rec.peak_mbps) or 0
			if mbps > 0 then
				members[#members + 1] = { uplink_id = uplink_id, interface = rec.interface, metric = rec.metric or 1, mbps = mbps }
				total = total + mbps
			end
		end
	end
	if total <= 0 or #members == 0 then return nil, 'no_successful_speedtests' end
	table.sort(members, function(a, b) return tostring(a.uplink_id) < tostring(b.uplink_id) end)
	local out = {}
	for i = 1, #members do
		local m = members[i]
		out[#out + 1] = {
			id = m.uplink_id,
			link_id = m.uplink_id,
			interface = m.interface,
			metric = math.max(1, math.floor(tonumber(m.metric or 1) or 1)),
			weight = math.max(1, math.floor((m.mbps / total) * 100 + 0.5)),
			measured_mbps = m.mbps,
		}
	end
	return out, nil
end

return M
