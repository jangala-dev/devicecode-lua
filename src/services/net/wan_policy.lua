-- services/net/wan_policy.lua
-- Pure WAN runtime policy for event-led speedtests and live weights.

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

local function runtime_opts(snapshot)
	local wan = snapshot and snapshot.wan or {}
	local lb = type(wan.load_balancing) == 'table' and wan.load_balancing or {}
	local rt = type(wan.runtime) == 'table' and wan.runtime or {}
	local sp = type(lb.speedtests) == 'table' and lb.speedtests
		or type(lb.speedtest) == 'table' and lb.speedtest
		or type(rt.speedtests) == 'table' and rt.speedtests
		or type(rt.speedtest) == 'table' and rt.speedtest
		or {}
	return sp
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
	return rt.weight_policy or rt.live_weight_policy or lb.weight_policy or lb.policy or 'balanced'
end

local function member_interface(member, uplink_id)
	member = member or {}
	return member.interface or uplink_id
end

local function gsm_source(member)
	local src = member and member.source or nil
	if type(src) ~= 'table' or src.kind ~= 'gsm-uplink' then return nil end
	return src.id
end

function M.gsm_uplink_state(snapshot, member)
	local id = gsm_source(member)
	if not id then return nil end
	return snapshot and snapshot.sources and snapshot.sources.gsm_uplinks and snapshot.sources.gsm_uplinks[id] or nil
end

function M.build_speedtest_request(snapshot, uplink_id, member)
	member = member or {}
	local iface_id = member_interface(member, uplink_id)
	local iface = snapshot.interfaces and snapshot.interfaces[iface_id] or nil
	local endpoint = type(iface) == 'table' and type(iface.endpoint) == 'table' and iface.endpoint or {}
	local gsm = M.gsm_uplink_state(snapshot, member)
	local gsm_linux = type(gsm) == 'table' and type(gsm.linux) == 'table' and gsm.linux or {}
	local metric = tonumber(member.metric) or 1
	return {
		interface = iface_id,
		device = member.device or member.linux_interface or member.ifname or endpoint.ifname or endpoint.device or endpoint.name or (iface and iface.device) or gsm_linux.ifname,
		url = member.speedtest_url,
		max_duration_s = member.speedtest_duration_s,
		uplink_id = tostring(uplink_id),
		metric = metric,
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

local function status_by_interface(snapshot, iface)
	local bh = snapshot and snapshot.backhaul or nil
	local uplinks = type(bh) == 'table' and bh.uplinks or nil
	if type(uplinks) ~= 'table' then return nil end
	for id, rec in pairs(uplinks) do
		if type(rec) == 'table' and (rec.interface == iface or rec.id == iface or id == iface) then
			if rec.observed == false then return nil end
			return rec
		end
	end
	return nil
end

local function status_online(st)
	return type(st) == 'table'
		and st.usable == true
		and st.state == 'online'
end

function M.uplink_observed_status(snapshot, uplink)
	return status_by_interface(snapshot, uplink and uplink.request and uplink.request.interface)
end

function M.uplink_online(snapshot, uplink)
	return status_online(M.uplink_observed_status(snapshot, uplink))
end

local function now_from_opts(opts)
	return opts and opts.now or nil
end

local function speedtest_ttl(snapshot)
	local cfg = runtime_opts(snapshot)
	return tonumber(cfg.interval_s or cfg.refresh_s or cfg.ttl_s or cfg.max_age_s)
end

local function speedtest_last_success(rec)
	if type(rec) ~= 'table' then return nil, nil end
	local last = type(rec.last_success) == 'table' and rec.last_success or nil
	local mbps = last and tonumber(last.mbps) or tonumber(rec.last_success_mbps) or tonumber(rec.peak_mbps)
	local completed = last and tonumber(last.completed_at)
		or tonumber(rec.last_success_at)
		or tonumber(rec.completed_at)
	if mbps == nil or mbps <= 0 then return nil, completed end
	return mbps, completed
end

local function speedtest_success_fresh(snapshot, rec, now)
	local mbps, completed = speedtest_last_success(rec)
	if mbps == nil then return false end
	local ttl = speedtest_ttl(snapshot)
	if not ttl or ttl <= 0 then return true end
	return now ~= nil and completed ~= nil and completed > 0 and now - completed < ttl
end

function M.speedtest_due(snapshot, uplink, opts)
	opts = opts or {}
	if not M.speedtest_enabled(snapshot) then return false, 'speedtests_disabled' end
	if not M.uplink_online(snapshot, uplink) then return false, 'not_online' end
	local generation = opts.generation or snapshot.generation
	local id = uplink.uplink_id
	local runtime = snapshot.wan_runtime or {}
	local rec = runtime.speedtests and runtime.speedtests[id]
	if rec and rec.state == 'running' and rec.generation == generation then return false, 'running' end
	local now = now_from_opts(opts)
	if rec and rec.retry_after and now and now < rec.retry_after then return false, 'retry_later' end
	if speedtest_success_fresh(snapshot, rec, now) then return false, 'fresh' end
	return true, 'due'
end

local function member_fingerprint(m)
	if type(m) ~= 'table' then return '' end
	return table.concat({ tostring(m.id), tostring(m.interface), tostring(m.metric), tostring(m.weight) }, ':')
end

function M.weights_equal(a, b)
	a, b = a or {}, b or {}
	if #a ~= #b then return false end
	local aa, bb = {}, {}
	for i = 1, #a do aa[i] = member_fingerprint(a[i]) end
	for i = 1, #b do bb[i] = member_fingerprint(b[i]) end
	table.sort(aa); table.sort(bb)
	for i = 1, #aa do if aa[i] ~= bb[i] then return false end end
	return true
end

function M.compute_weights(snapshot, generation, opts)
	opts = opts or {}
	local runtime = snapshot.wan_runtime or {}
	local tests = runtime.speedtests or {}
	local measured, total = {}, 0
	local uplinks = M.collect_uplinks(snapshot)
	local cfg = runtime_opts(snapshot)
	local probe_weight = math.max(1, math.floor(tonumber(cfg.probe_weight) or 1))
	local weight_scale = math.max(1, math.floor(tonumber(cfg.weight_scale) or 100))

	for _, uplink in ipairs(uplinks) do
		local id = uplink.uplink_id
		local rec = tests[id]
		local mbps = nil
		if rec then
			local success_mbps = speedtest_last_success(rec)
			if success_mbps and (rec.generation == generation or speedtest_success_fresh(snapshot, rec, now_from_opts(opts))) then
				mbps = success_mbps
			end
		end
		if mbps and mbps > 0 then total = total + mbps end
		measured[id] = mbps
	end
	if total <= 0 then return nil, 'no_successful_speedtests' end

	local out = {}
	for _, uplink in ipairs(uplinks) do
		local id = uplink.uplink_id
		local mbps = measured[id]
		local metric = math.max(1, math.floor(tonumber(uplink.request.metric) or 1))
		local weight, probe = probe_weight, true
		if mbps and mbps > 0 then
			weight = math.max(1, math.floor((mbps / total) * weight_scale + 0.5))
			probe = false
		end
		out[#out + 1] = {
			id = id,
			interface = uplink.request.interface,
			metric = metric,
			weight = weight,
			measured_mbps = mbps,
			probe = probe,
		}
	end
	return out, nil
end

return M
