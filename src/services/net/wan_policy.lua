-- services/net/wan_policy.lua
-- Pure WAN runtime policy for event-led speedtests and live weights.

local tablex = require 'shared.table'

local M = {}

local DEFAULT_SPEEDTEST_INTERVAL_S = 6 * 60 * 60
local DEFAULT_SPEEDTEST_RETRY_AFTER_S = 10
local DEFAULT_SPEEDTEST_RETRY_MAX_S = 60 * 60
local HARD_MAX_SPEEDTEST_DURATION_S = 1

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


local function bounded_number(v, default, minv)
	local n = tonumber(v)
	if n == nil then n = default end
	if minv ~= nil and n < minv then n = minv end
	return n
end

function M.speedtest_retry_delay_s(snapshot, rec)
	local cfg = runtime_opts(snapshot)
	local base = bounded_number(cfg.retry_after_s or cfg.retry_base_s or cfg.retry_s,
		DEFAULT_SPEEDTEST_RETRY_AFTER_S, 1)
	local cap = bounded_number(cfg.retry_max_s or cfg.max_retry_after_s or cfg.retry_cap_s,
		DEFAULT_SPEEDTEST_RETRY_MAX_S, base)
	if cap < base then cap = base end
	local failures = math.floor(tonumber(rec and (rec.failure_count or rec.consecutive_failures)) or 1)
	if failures < 1 then failures = 1 end
	local delay = base
	for _ = 2, failures do
		delay = delay * 2
		if delay >= cap then return cap end
	end
	if delay > cap then delay = cap end
	return delay
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

local function source_kind(member, status)
	local src = member and member.source or nil
	if type(src) == 'table' and type(src.kind) == 'string' and src.kind ~= '' then return src.kind end
	local st_src = status and status.source or nil
	if type(st_src) == 'table' and type(st_src.kind) == 'string' and st_src.kind ~= '' then return st_src.kind end
	return 'host-multiwan'
end

local function source_id(member, status)
	local src = member and member.source or nil
	if type(src) == 'table' and src.id ~= nil then return src.id end
	local st_src = status and status.source or nil
	if type(st_src) == 'table' and st_src.id ~= nil then return st_src.id end
	return nil
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
	local duration = tonumber(member.speedtest_duration_s) or HARD_MAX_SPEEDTEST_DURATION_S
	if duration <= 0 or duration > HARD_MAX_SPEEDTEST_DURATION_S then duration = HARD_MAX_SPEEDTEST_DURATION_S end
	return {
		interface = iface_id,
		device = member.device or member.linux_interface or member.ifname or endpoint.ifname or endpoint.device or endpoint.name or (iface and iface.device) or gsm_linux.ifname,
		url = member.speedtest_url,
		max_duration_s = duration,
		uplink_id = tostring(uplink_id),
		metric = metric,
	}
end

function M.collect_uplinks(snapshot)
	local out = {}
	local members = snapshot and snapshot.wan and snapshot.wan.configured_members or {}
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

local function normalise_address(addr)
	if type(addr) ~= 'table' then return nil end
	local address = addr.address or addr.ip or addr.addr
	if type(address) ~= 'string' or address == '' then return nil end
	if address == '0.0.0.0' or address == '::' then return nil end
	return {
		family = tostring(addr.family or addr.af or 'ipv4'),
		address = address,
		source = addr.source,
	}
end

function M.measurement(snapshot, uplink)
	local status = M.uplink_observed_status(snapshot, uplink)
	local addr = normalise_address(status and status.path_address)
	local req = uplink and uplink.request or {}
	local member = uplink and uplink.member or {}
	local parts = {
		schema = 'devicecode.net.speedtest-key/1',
		uplink_id = tostring(uplink and uplink.uplink_id or ''),
		interface = tostring(req.interface or ''),
		device = tostring(req.device or ''),
		source_kind = tostring(source_kind(member, status) or ''),
		source_id = tostring(source_id(member, status) or ''),
		address_family = addr and addr.family or 'unknown',
		address = addr and addr.address or 'unknown',
		address_known = addr ~= nil,
		speedtest_url = tostring(req.url or ''),
	}
	local key = table.concat({
		'v1', parts.uplink_id, parts.interface, parts.device,
		parts.source_kind, parts.source_id, parts.address_family,
		parts.address, parts.speedtest_url,
	}, '|')
	parts.key = key
	parts.address_source = addr and addr.source or 'unobserved'
	return parts, nil
end

function M.measurement_key(snapshot, uplink)
	local m, err = M.measurement(snapshot, uplink)
	return m and m.key or nil, err, m
end

local function now_from_opts(opts)
	return opts and opts.now or nil
end

local function speedtest_ttl(snapshot)
	local cfg = runtime_opts(snapshot)
	local ttl = tonumber(cfg.interval_s or cfg.refresh_s or cfg.ttl_s or cfg.max_age_s)
	if ttl == nil then return DEFAULT_SPEEDTEST_INTERVAL_S end
	return ttl
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

local function speedtest_last_key(rec)
	if type(rec) ~= 'table' then return nil end
	local last = type(rec.last_success) == 'table' and rec.last_success or nil
	return last and (last.measurement_key or last.path_key) or rec.last_success_key or rec.measurement_key
end

local function speedtest_last_address(rec)
	local last = type(rec) == 'table' and type(rec.last_success) == 'table' and rec.last_success or nil
	local m = last and type(last.measurement) == 'table' and last.measurement or nil
	return m and m.address or nil
end

local function address_known(address)
	return type(address) == 'string' and address ~= '' and address ~= 'unknown'
end

local function speedtest_last_address_known(rec)
	return address_known(speedtest_last_address(rec))
end

local function weak_key_for_measurement(m)
	if type(m) ~= 'table' then return nil end
	return table.concat({
		'v1', tostring(m.uplink_id or ''), tostring(m.interface or ''), tostring(m.device or ''),
		tostring(m.source_kind or ''), tostring(m.source_id or ''), 'unknown', 'unknown',
		tostring(m.speedtest_url or ''),
	}, '|')
end

local function speedtest_success_fresh(snapshot, rec, now)
	local mbps, completed = speedtest_last_success(rec)
	if mbps == nil then return false end
	local ttl = speedtest_ttl(snapshot)
	if not ttl or ttl <= 0 then return true end
	return now ~= nil and completed ~= nil and completed > 0 and now - completed < ttl
end

local function speedtest_success_valid(snapshot, rec, now, key, measurement)
	if not speedtest_success_fresh(snapshot, rec, now) then return false end
	if key == nil then return false end
	if speedtest_last_key(rec) == key then return true end
	-- If the original measurement was admitted before an address was observable,
	-- allow that fresh result to be used while the current path is being
	-- strengthened with a known address.  The manager will re-key the cached
	-- success on the skip path so future IP changes still matter.
	if measurement and measurement.address_known == true and not speedtest_last_address_known(rec)
		and speedtest_last_key(rec) == weak_key_for_measurement(measurement) then
		return true
	end
	return false
end

function M.speedtest_due(snapshot, uplink, opts)
	opts = opts or {}
	if not M.speedtest_enabled(snapshot) then return false, 'speedtests_disabled' end
	if not M.uplink_online(snapshot, uplink) then return false, 'not_online' end
	local key, _, measurement = M.measurement_key(snapshot, uplink)
	local generation = opts.generation or snapshot.generation
	local id = uplink.uplink_id
	local runtime = snapshot.wan_runtime or {}
	local rec = runtime.speedtests and runtime.speedtests[id]
	if rec and rec.state == 'running' and rec.generation == generation then return false, 'running' end
	local now = now_from_opts(opts)
	if rec and rec.retry_after and now and now < rec.retry_after then
		local retry_key = rec.measurement_key or rec.current_measurement_key or speedtest_last_key(rec)
		if retry_key == key then return false, 'retry_later' end
	end
	if speedtest_success_valid(snapshot, rec, now, key, measurement) then
		if measurement and measurement.address_known == true and not speedtest_last_address_known(rec) then
			return false, 'fresh_weak_path'
		end
		return false, 'fresh_same_path'
	end
	if speedtest_success_fresh(snapshot, rec, now) and speedtest_last_key(rec) ~= nil then
		local last_addr = speedtest_last_address(rec)
		if measurement and measurement.address_known == true and address_known(last_addr) and last_addr ~= measurement.address then
			return true, 'path_changed_ip'
		end
		return true, 'path_changed'
	end
	if speedtest_success_fresh(snapshot, rec, now) then return true, 'missing_previous_key' end
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
			local key, _, measurement = M.measurement_key(snapshot, uplink)
			local success_mbps = speedtest_last_success(rec)
			if success_mbps and speedtest_success_valid(snapshot, rec, now_from_opts(opts), key, measurement) then
				mbps = success_mbps
			end
		end
		if mbps and mbps > 0 then total = total + mbps end
		measured[id] = mbps
	end
	local out = {}
	if total <= 0 then
		local online = {}
		for _, uplink in ipairs(uplinks) do
			if M.uplink_online(snapshot, uplink) then online[#online + 1] = uplink end
		end
		if #online == 0 then return nil, 'no_online_wan_uplinks' end
		local fallback_weight = math.max(1, math.floor((weight_scale / #online) + 0.5))
		for _, uplink in ipairs(online) do
			out[#out + 1] = {
				id = uplink.uplink_id,
				interface = uplink.request.interface,
				metric = math.max(1, math.floor(tonumber(uplink.request.metric) or 1)),
				weight = fallback_weight,
				measured_mbps = nil,
				probe = true,
				reason = 'no_successful_speedtests',
			}
		end
		return out, nil
	end

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
