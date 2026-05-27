-- services/net/domain/multiwan.lua
-- Product-level WAN and multi-WAN policy intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'enabled', 'members', 'health', 'runtime', 'failover',
	'load_balancing', 'rules', 'metadata', 'extensions',
}

local MEMBER_ALLOWED = {
	'id', 'interface', 'source', 'mwan_metric', 'weight', 'dynamic_weight', 'family',
	'track_ip', 'health', 'reliability', 'count', 'timeout', 'interval', 'up', 'down',
	'enabled', 'disabled', 'speedtest_url', 'speedtest_duration_s', 'metadata', 'extensions',
}

local RULE_ALLOWED = {
	'family', 'proto', 'src_ip', 'dest_ip', 'src_port', 'dest_port',
	'policy', 'sticky', 'timeout', 'enabled', 'disabled', 'metadata', 'extensions',
}


local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function has_source(member)
	return type(member) == 'table' and member.source ~= nil
end

local function route_metric_keys(t)
	local ks = sorted_keys(t)
	table.sort(ks, function(a, b)
		local source_a, source_b = has_source(t[a]), has_source(t[b])
		if source_a ~= source_b then return not source_a end
		return tostring(a) < tostring(b)
	end)
	return ks
end

local function clean_rule(id, r, policy_name)
	r = schema.copy(r or {})
	local ok, ferr = schema.check_allowed_fields(r, RULE_ALLOWED, { 'net', 'wan', 'rules', id })
	if not ok then return nil, ferr end
	if r.enabled == false or r.disabled == true then return nil, nil, true end
	if type(id) ~= 'string' or id == '' then return nil, schema.err({ 'net', 'wan', 'rules' }, 'rule ids must be non-empty strings') end
	if type(r.policy) ~= 'string' or r.policy == '' then return nil, schema.err({ 'net', 'wan', 'rules', id, 'policy' }, 'must be a non-empty string') end
	if r.policy ~= policy_name then return nil, schema.err({ 'net', 'wan', 'rules', id, 'policy' }, 'must match wan.load_balancing.policy') end
	local out = {
		family = r.family or 'ipv4',
		policy = r.policy,
		proto = r.proto,
		src_ip = r.src_ip,
		dest_ip = r.dest_ip,
		src_port = r.src_port,
		dest_port = r.dest_port,
		sticky = r.sticky == true,
		timeout = r.timeout,
	}
	local extended, xerr = schema.with_optional_extensions(out, r, { 'net', 'wan', 'rules', id })
	if not extended then return nil, xerr end
	return extended, nil
end

local function normalise_rules(t)
	local src = t.rules or {}
	local lb = schema.is_plain_table(t.load_balancing) and t.load_balancing or {}
	local policy_name = lb.policy or 'balanced'
	if src ~= nil and not schema.is_plain_table(src) then return nil, schema.err({ 'net', 'wan', 'rules' }, 'must be a map') end
	local out = {}
	for _, id in ipairs(sorted_keys(src)) do
		local rec, err, skipped = clean_rule(id, src[id], policy_name)
		if err then return nil, err end
		if not skipped and rec then out[id] = rec end
	end
	return out, nil
end

local function clean_member(id, m, index)
	m = schema.copy(m or {})
	local ok, ferr = schema.check_allowed_fields(m, MEMBER_ALLOWED, { 'net', 'wan', 'members', id })
	if not ok then return nil, ferr end
	m.id = m.id or id
	m.interface = m.interface or id
	m.mwan_metric = math.max(1, math.floor(tonumber(m.mwan_metric) or 1))
	m.weight = math.max(1, math.floor(tonumber(m.weight) or 1))
	m.route_metric = 10 + index
	local src = m.source
	if src ~= nil then
		if not schema.is_plain_table(src) then return nil, schema.err({ 'net', 'wan', 'members', id, 'source' }, 'must be a table') end
		if src.kind ~= 'gsm-uplink' then return nil, schema.err({ 'net', 'wan', 'members', id, 'source', 'kind' }, 'must be gsm-uplink') end
		if type(src.id) ~= 'string' or src.id == '' then return nil, schema.err({ 'net', 'wan', 'members', id, 'source', 'id' }, 'must be a non-empty string') end
		m.source = { kind = 'gsm-uplink', id = src.id }
	end
	return m, nil
end

local function normalise_members(t)
	local src = t.members or {}
	if src ~= nil and not schema.is_plain_table(src) then return nil, schema.err({ 'net', 'wan', 'members' }, 'must be a map') end
	local out = {}
	local keys = route_metric_keys(src)
	for i, id in ipairs(keys) do
		if type(id) ~= 'string' or id == '' then return nil, schema.err({ 'net', 'wan', 'members' }, 'member ids must be non-empty strings') end
		local rec, err = clean_member(id, src[id], i)
		if not rec then return nil, err end
		out[id] = rec
	end
	return out, nil
end

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'wan' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'wan' })
	if not ok then return nil, ferr end
	local members, merr = normalise_members(t)
	if not members then return nil, merr end
	local rules, rerr = normalise_rules(t)
	if not rules then return nil, rerr end
	local out = {
		enabled = t.enabled ~= false,
		members = members,
		rules = rules,
		health = schema.copy(t.health or {}),
		runtime = schema.copy(t.runtime or {}),
		failover = schema.copy(t.failover or {}),
		load_balancing = schema.copy(t.load_balancing or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'wan' })
end

return M
