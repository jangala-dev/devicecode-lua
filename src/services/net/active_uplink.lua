-- services/net/active_uplink.lua
--
-- Pure selection of the uplink currently carrying traffic.
--
-- mwan3's live policy is the routing truth when HAL reports it: the default
-- rule uses the configured load-balancing policy, and mwan3 lists only the
-- members it is sending traffic to.  Without a usable policy report, the
-- lowest-metric online member is active, which is what mwan3 does under
-- strict failover.  With no online member, traffic follows `last_resort`.
--
-- Result:
--   {
--     status     = 'uplink' | 'last_resort' | 'none' | 'unknown',
--     uplink_id  = <member id carrying most traffic> | nil,
--     uplink_ids = { <every member carrying traffic> },
--     interface, metric,
--     source     = 'mwan3_policy' | 'lowest_metric' | nil,
--   }

local M = {}

local DEFAULT_POLICY = 'balanced'
local FAMILY = 'ipv4'

-- mwan3's names for traffic leaving through no member.
local FALLBACK_STATUS = {
	default = 'last_resort',
	unreachable = 'none',
	blackhole = 'none',
}

local function is_table(v) return type(v) == 'table' end

local function online(rec)
	return is_table(rec) and rec.state == 'online' and rec.usable == true
end

local function metric_of(rec)
	return tonumber(rec and rec.metric) or 1
end

local function sorted_ids(uplinks)
	local ids = {}
	for id, rec in pairs(uplinks or {}) do
		if is_table(rec) then ids[#ids + 1] = tostring(id) end
	end
	table.sort(ids)
	return ids
end

local function result(status, uplinks, ids, source)
	local out = { status = status, uplink_ids = ids or {}, source = source }
	local first = ids and ids[1]
	if first then
		local rec = uplinks[first]
		out.uplink_id = first
		out.interface = rec.interface or first
		out.metric = metric_of(rec)
	end
	return out
end

local function multiwan(snapshot)
	local observed = snapshot and snapshot.observed or nil
	local mw = observed and observed.snapshot and observed.snapshot.multiwan or nil
	if not is_table(mw) then mw = observed and observed.multiwan or nil end
	return is_table(mw) and mw or nil
end

local function policy_name(snapshot)
	local lb = snapshot and snapshot.wan and snapshot.wan.load_balancing or nil
	local p = is_table(lb) and lb.policy or nil
	return type(p) == 'string' and p ~= '' and p or DEFAULT_POLICY
end

local function last_resort(snapshot)
	local lr = snapshot and snapshot.wan and snapshot.wan.last_resort or nil
	return type(lr) == 'string' and lr ~= '' and lr or 'default'
end

local function policy_members(policies, name)
	local fam = is_table(policies) and policies[FAMILY] or nil
	local list = is_table(fam) and fam[name] or nil
	if not is_table(list) or #list == 0 then return nil end
	return list
end

-- Map a policy member's interface name to a configured uplink id.  Policy
-- members name interfaces, which need not match member ids, so interfaces are
-- matched first; the id is only a fallback for records without an interface.
local function uplink_for(name, uplinks, mw, semantic)
	if type(name) ~= 'string' or name == '' then return nil end
	if not semantic then
		-- Raw mwan3 names: HAL keeps each member's mwan3 name in .interface.
		for sem, st in pairs(mw.interfaces_by_semantic or {}) do
			if is_table(st) and st.interface == name then name = tostring(sem); break end
		end
	end
	-- Several members may share an interface: the lowest metric owns it.
	local best
	for _, id in ipairs(sorted_ids(uplinks)) do
		if uplinks[id].interface == name and (best == nil or metric_of(uplinks[id]) < metric_of(uplinks[best])) then
			best = id
		end
	end
	if best then return best end
	if is_table(uplinks[name]) and uplinks[name].interface == nil then return name end
	return nil
end

local function from_policy(snapshot, uplinks)
	local mw = multiwan(snapshot)
	if not mw then return nil end
	local name = policy_name(snapshot)
	local list, semantic = policy_members(mw.policies_by_semantic, name), true
	if not list then list, semantic = policy_members(mw.policies, name), false end
	if not list then return nil end

	local carrying, percent, fallback = {}, {}, nil
	for i = 1, #list do
		local m = list[i]
		if is_table(m) then
			local pct = tonumber(m.percent)
			local id = uplink_for(m.interface, uplinks, mw, semantic)
			if id then
				-- mwan3 lists only members carrying traffic; its integer percent
				-- can round a small share down to 0, so it only orders them.
				if percent[id] == nil then
					carrying[#carrying + 1] = id
					percent[id] = pct or 0
				end
			elseif fallback == nil and type(m.interface) == 'string' then
				fallback = FALLBACK_STATUS[m.interface]
			end
		end
	end
	if #carrying > 0 then
		table.sort(carrying, function(a, b)
			if percent[a] ~= percent[b] then return percent[a] > percent[b] end
			local ma, mb = metric_of(uplinks[a]), metric_of(uplinks[b])
			if ma ~= mb then return ma < mb end
			return a < b
		end)
		return result('uplink', uplinks, carrying, 'mwan3_policy')
	end
	if fallback then return result(fallback, uplinks, {}, 'mwan3_policy') end
	return nil
end

local function from_metric(snapshot, uplinks)
	local ids = sorted_ids(uplinks)
	local best, known = nil, false
	for _, id in ipairs(ids) do
		local rec = uplinks[id]
		if rec.state ~= nil and rec.state ~= 'unknown' then known = true end
		if online(rec) and (best == nil or metric_of(rec) < best) then best = metric_of(rec) end
	end
	if best ~= nil then
		local tier = {}
		for _, id in ipairs(ids) do
			if online(uplinks[id]) and metric_of(uplinks[id]) == best then tier[#tier + 1] = id end
		end
		return result('uplink', uplinks, tier, 'lowest_metric')
	end
	if #ids == 0 then return result('none', uplinks, {}, nil) end
	if not known then return result('unknown', uplinks, {}, nil) end
	return result(FALLBACK_STATUS[last_resort(snapshot)] or 'last_resort', uplinks, {}, nil)
end

function M.select(snapshot, uplinks)
	uplinks = is_table(uplinks) and uplinks or {}
	return from_policy(snapshot, uplinks) or from_metric(snapshot, uplinks)
end

function M.changed(a, b)
	if a == nil and b == nil then return false end
	if not is_table(a) or not is_table(b) then return true end
	if a.status ~= b.status or a.uplink_id ~= b.uplink_id then return true end
	local ai, bi = a.uplink_ids or {}, b.uplink_ids or {}
	if #ai ~= #bi then return true end
	for i = 1, #ai do if ai[i] ~= bi[i] then return true end end
	return false
end

return M
