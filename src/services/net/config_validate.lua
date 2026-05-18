-- services/net/config_validate.lua
-- Cross-domain semantic validation for normalised NET intent.

local schema = require 'services.net.schema'

local M = {}

local function has(t, id) return type(t) == 'table' and t[id] ~= nil end
local function err(path, msg) return schema.err(path, msg) end

local function check_ref(map, id, path, kind)
	if id == nil then return true, nil end
	if type(id) ~= 'string' or id == '' then return nil, err(path, kind .. ' reference must be a non-empty string') end
	if not has(map, id) then return nil, err(path, 'references unknown ' .. kind .. ' ' .. tostring(id)) end
	return true, nil
end

local function validate_interfaces(intent)
	for id, iface in pairs(intent.interfaces or {}) do
		local ok, e = check_ref(intent.segments, iface.segment, { 'net', 'interfaces', id, 'segment' }, 'segment')
		if not ok then return nil, e end
		for i, seg_id in ipairs(iface.segments or {}) do
			ok, e = check_ref(intent.segments, seg_id, { 'net', 'interfaces', id, 'segments', i }, 'segment')
			if not ok then return nil, e end
		end
		if iface.parent ~= nil and has(intent.interfaces, iface.parent) == false then
			return nil, err({ 'net', 'interfaces', id, 'parent' }, 'references unknown interface ' .. tostring(iface.parent))
		end
	end
	return true, nil
end

local function validate_segments(intent)
	local profiles = intent.shaping and intent.shaping.profiles or {}
	local host_sources = intent.dns and intent.dns.host_files and intent.dns.host_files.sources or {}
	local zones = intent.firewall and intent.firewall.zones or {}
	for id, seg in pairs(intent.segments or {}) do
		local zone = seg.firewall and seg.firewall.zone or nil
		if zone ~= nil and type(zones) == 'table' and next(zones) ~= nil and not zones[zone] then
			return nil, err({ 'net', 'segments', id, 'firewall', 'zone' }, 'references unknown firewall zone ' .. tostring(zone))
		end
		local profile = seg.shaping and seg.shaping.profile or nil
		if profile ~= nil and type(profiles) == 'table' and next(profiles) ~= nil and not profiles[profile] then
			return nil, err({ 'net', 'segments', id, 'shaping', 'profile' }, 'references unknown shaping profile ' .. tostring(profile))
		end
		for i, source in ipairs((seg.dns and seg.dns.host_files) or {}) do
			if type(host_sources) == 'table' and next(host_sources) ~= nil and not host_sources[source] then
				return nil, err({ 'net', 'segments', id, 'dns', 'host_files', i }, 'references unknown DNS host file source ' .. tostring(source))
			end
		end
	end
	return true, nil
end

local function validate_wan(intent)
	-- If no interface catalogue is declared, member references are external provider names.
	if type(intent.interfaces) ~= 'table' or next(intent.interfaces) == nil then return true, nil end
	for id, member in pairs((intent.wan and intent.wan.members) or {}) do
		local iface = member.interface or member.network_interface or member.openwrt_interface or member.iface
		local ok, e = check_ref(intent.interfaces, iface, { 'net', 'wan', 'members', id, 'interface' }, 'interface')
		if not ok then return nil, e end
	end
	return true, nil
end

local function validate_firewall(intent)
	local zones = intent.firewall and intent.firewall.zones or {}
	if type(zones) ~= 'table' or next(zones) == nil then return true, nil end
	for id, pol in pairs((intent.firewall and intent.firewall.policies) or {}) do
		if pol.from ~= nil and not zones[pol.from] then
			return nil, err({ 'net', 'firewall', 'policies', id, 'from' }, 'references unknown firewall zone ' .. tostring(pol.from))
		end
		if pol.to ~= nil and not zones[pol.to] then
			return nil, err({ 'net', 'firewall', 'policies', id, 'to' }, 'references unknown firewall zone ' .. tostring(pol.to))
		end
	end
	return true, nil
end

local function validate_dhcp(intent)
	for id, r in pairs((intent.dhcp and intent.dhcp.reservations) or {}) do
		if r.segment ~= nil and not has(intent.segments, r.segment) then
			return nil, err({ 'net', 'dhcp', 'reservations', id, 'segment' }, 'references unknown segment ' .. tostring(r.segment))
		end
		if r.interface ~= nil and not has(intent.interfaces, r.interface) then
			return nil, err({ 'net', 'dhcp', 'reservations', id, 'interface' }, 'references unknown interface ' .. tostring(r.interface))
		end
	end
	return true, nil
end

function M.validate(intent)
	local ok, e = validate_interfaces(intent); if not ok then return nil, e end
	ok, e = validate_segments(intent); if not ok then return nil, e end
	ok, e = validate_wan(intent); if not ok then return nil, e end
	ok, e = validate_firewall(intent); if not ok then return nil, e end
	ok, e = validate_dhcp(intent); if not ok then return nil, e end
	return true, nil
end

return M
