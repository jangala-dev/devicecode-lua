-- services/net/metrics.lua
-- NET observability metrics helpers.

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'

local perform = fibers.perform

local M = {}

local function obs_log(svc, level, payload)
	if svc and type(svc.obs_log) == 'function' then svc:obs_log(level, payload) end
end

local COUNTER_STATS = {
	'rx_bytes',
	'rx_packets',
	'rx_dropped',
	'rx_errors',
	'tx_bytes',
	'tx_packets',
	'tx_dropped',
	'tx_errors',
}

local STATIC_COUNTER_ALIASES = {
	{ alias = 'adm', interface = 'adm' },
	{ alias = 'jan', interface = 'jan' },
	{ alias = 'wan', interface = 'wan' },
}

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t or {}) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function has_counter_interface(snapshot, id)
	return type(id) == 'string' and id ~= ''
		and (type(snapshot.interfaces) == 'table' and snapshot.interfaces[id] ~= nil
			or type(snapshot.segments) == 'table' and snapshot.segments[id] ~= nil)
end

local function add_counter_alias(list, seen_alias, seen_iface, alias, iface)
	if type(alias) ~= 'string' or alias == '' or type(iface) ~= 'string' or iface == '' then return end
	if seen_alias[alias] or seen_iface[iface] then return end
	seen_alias[alias] = true
	seen_iface[iface] = true
	list[#list + 1] = { alias = alias, interface = iface }
end

local function counter_aliases(snapshot)
	snapshot = snapshot or {}
	local out, seen_alias, seen_iface = {}, {}, {}
	for i = 1, #STATIC_COUNTER_ALIASES do
		local rec = STATIC_COUNTER_ALIASES[i]
		if has_counter_interface(snapshot, rec.interface) then add_counter_alias(out, seen_alias, seen_iface, rec.alias, rec.interface) end
	end

	local members = snapshot.wan and snapshot.wan.configured_members or {}
	for _, member_id in ipairs(sorted_keys(members)) do
		local member = members[member_id]
		local iface = type(member) == 'table' and (member.interface or member_id) or member_id
		add_counter_alias(out, seen_alias, seen_iface, tostring(member_id), iface)
	end
	return out
end

local function counter_request_from_aliases(aliases)
	local interfaces = {}
	for i = 1, #(aliases or {}) do interfaces[#interfaces + 1] = aliases[i].interface end
	return { interfaces = interfaces, stats = COUNTER_STATS }
end

local function publish_counter_metrics(svc, counters, aliases)
	if not svc or type(svc.obs_metric) ~= 'function' or type(counters) ~= 'table' then return true, nil end
	local alias_by_interface = {}
	for i = 1, #(aliases or {}) do alias_by_interface[aliases[i].interface] = aliases[i].alias end
	for _, iface in ipairs(sorted_keys(counters)) do
		local rec = counters[iface]
		local alias = alias_by_interface[iface]
		local stats = type(rec) == 'table' and rec.statistics or nil
		if alias and type(stats) == 'table' then
			for i = 1, #COUNTER_STATS do
				local stat = COUNTER_STATS[i]
				local value = tonumber(stats[stat])
				if value ~= nil then
					svc:obs_metric(stat, {
						value = value,
						namespace = { 'net', alias, stat },
					})
				end
			end
		end
	end
	return true, nil
end


function M.poll_counter_metrics_once(state)
	if not state.conn or not state.hal or type(state.hal.read_counters_op) ~= 'function' then return true, nil end
	local snap = state.model and state.model:snapshot() or {}
	if snap.ready ~= true then return true, nil end
	local aliases = counter_aliases(snap)
	if #aliases == 0 then return true, nil end
	local ok, result = pcall(function ()
		return perform(state.hal:read_counters_op(counter_request_from_aliases(aliases), {
			timeout = state.counter_poll_timeout_s,
		}))
	end)
	if not ok then
		obs_log(state.svc, 'warn', { what = 'net_counter_poll_failed', err = tostring(result) })
		return true, nil
	end
	if not result or result.ok ~= true then
		obs_log(state.svc, 'debug', { what = 'net_counter_poll_unavailable', err = result and result.err or 'no_result' })
		return true, nil
	end
	publish_counter_metrics(state.svc, result.counters, aliases)
	return true, nil
end

function M.counter_metrics_loop(state)
	local interval = tonumber(state.counter_poll_interval_s) or 60
	if interval <= 0 then interval = 60 end
	while true do
		M.poll_counter_metrics_once(state)
		local snap = state.model and state.model:snapshot() or {}
		local delay = snap.ready == true and interval or math.min(interval, 1.0)
		perform(sleep.sleep_op(delay))
	end
end

M._test = {
	counter_aliases = counter_aliases,
	counter_request_from_aliases = counter_request_from_aliases,
	publish_counter_metrics = publish_counter_metrics,
	counter_stats = COUNTER_STATS,
}

return M
