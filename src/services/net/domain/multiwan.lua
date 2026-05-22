-- services/net/domain/multiwan.lua
-- Product-level WAN and multi-WAN policy intent.

local schema = require 'services.net.schema'

local M = {}

local ALLOWED = {
	'enabled', 'policy', 'members', 'uplinks', 'health', 'runtime', 'failover',
	'load_balancing', 'metadata', 'extensions',
}

local function normalise_member(m)
	m = schema.copy(m or {})
	local src = m.source
	if type(src) == 'table' and src.kind == 'modem' then
		m.source = {
			kind = 'gsm-uplink',
			id = src.modem_id or src.id or src.role,
			compat = schema.copy(src),
		}
	end
	return m
end

local function normalise_members(t)
	local src = t.uplinks or t.members or {}
	local out = {}
	for id, rec in pairs(src) do
		out[id] = normalise_member(rec)
	end
	return out
end

function M.normalise(v)
	local t, err = schema.optional_plain_table(v, { 'net', 'wan' })
	if not t then return nil, err end
	local ok, ferr = schema.check_allowed_fields(t, ALLOWED, { 'net', 'wan' })
	if not ok then return nil, ferr end
	local out = {
		enabled = t.enabled ~= false,
		policy = t.policy or 'failover',
		members = normalise_members(t),
		health = schema.copy(t.health or {}),
		runtime = schema.copy(t.runtime or {}),
		failover = schema.copy(t.failover or {}),
		load_balancing = schema.copy(t.load_balancing or {}),
	}
	return schema.with_optional_extensions(out, t, { 'net', 'wan' })
end

return M
