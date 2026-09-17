-- services/net/config_validate.lua
-- Cross-domain semantic validation for normalised NET intent.

local schema = require 'services.net.schema'
local ipv4 = require 'services.net.ipv4'
local firewall_values = require 'services.net.firewall_validate'

local M = {}

local function has(t, id) return type(t) == 'table' and t[id] ~= nil end
local function err(path, msg) return schema.err(path, msg) end

local function check_ref(map, id, path, kind)
	if id == nil then return true, nil end
	if type(id) ~= 'string' or id == '' then return nil, err(path, kind .. ' reference must be a non-empty string') end
	if not has(map, id) then return nil, err(path, 'references unknown ' .. kind .. ' ' .. tostring(id)) end
	return true, nil
end

local function known_l3_ref(intent, id)
	return has(intent.interfaces, id) or has(intent.segments, id)
end

local function check_l3_ref(intent, id, path)
	if type(id) ~= 'string' or id == '' then
		return nil, err(path, 'interface reference must be a non-empty string')
	end
	if not known_l3_ref(intent, id) then
		return nil, err(path, 'references unknown interface or segment ' .. tostring(id))
	end
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
			return nil, err({ 'net', 'interfaces', id, 'parent' },
				'references unknown interface ' .. tostring(iface.parent))
		end
	end
	return true, nil
end

local function validate_segments(intent)
	local host_sources = intent.dns and intent.dns.host_files and intent.dns.host_files.sources or {}
	local zones = intent.firewall and intent.firewall.zones or {}
	for id, seg in pairs(intent.segments or {}) do
		local zone = seg.firewall and seg.firewall.zone or nil
		if zone ~= nil and type(zones) == 'table' and next(zones) ~= nil and not zones[zone] then
			return nil, err({ 'net', 'segments', id, 'firewall', 'zone' },
				'references unknown firewall zone ' .. tostring(zone))
		end
		for i, source in ipairs((seg.dns and seg.dns.host_files) or {}) do
			if type(host_sources) == 'table' and next(host_sources) ~= nil and not host_sources[source] then
				return nil, err({ 'net', 'segments', id, 'dns', 'host_files', i },
					'references unknown DNS host file source ' .. tostring(source))
			end
		end
	end
	return true, nil
end


local function validate_routing(intent)
	if type(intent.interfaces) ~= 'table' or next(intent.interfaces) == nil then return true, nil end
	for id, route in pairs((intent.routing and intent.routing.routes) or {}) do
		local ok, e = check_l3_ref(intent, route.interface, { 'net', 'routing', 'routes', id, 'interface' })
		if not ok then return nil, e end
	end
	return true, nil
end

local function validate_wan(intent)
	-- If no interface catalogue is declared, member references are external provider names.
	if type(intent.interfaces) ~= 'table' or next(intent.interfaces) == nil then return true, nil end
	for id, member in pairs((intent.wan and intent.wan.members) or {}) do
		local iface = member.interface
		local src = member.source
		if not (type(src) == 'table' and src.kind == 'gsm-uplink') then
			local ok, e = check_l3_ref(intent, iface, { 'net', 'wan', 'members', id, 'interface' })
			if not ok then return nil, e end
		end
	end
	return true, nil
end

local function validate_firewall(intent)
	local zones = intent.firewall and intent.firewall.zones or {}
	for id, rule in pairs(intent.firewall.rules or {}) do
		local ok, e = firewall_values.rule(rule, zones, { 'net', 'firewall', 'rules', id })
		if not ok then return nil, e end
	end
	for id, pol in pairs((intent.firewall and intent.firewall.policies) or {}) do
		if pol.from ~= nil and not zones[pol.from] then
			return nil, err({ 'net', 'firewall', 'policies', id, 'from' },
				'references unknown firewall zone ' .. tostring(pol.from))
		end
		if pol.to ~= nil and not zones[pol.to] then
			return nil, err({ 'net', 'firewall', 'policies', id, 'to' },
				'references unknown firewall zone ' .. tostring(pol.to))
		end
	end
	return true, nil
end

local function validate_dhcp(intent)
	for id, r in pairs((intent.dhcp and intent.dhcp.reservations) or {}) do
		if not schema.is_plain_table(r) then
			return nil, err({ 'net', 'dhcp', 'reservations', id },
			'must be a reservation table')
		end
		if r.segment ~= nil and not has(intent.segments, r.segment) then
			return nil, err({ 'net', 'dhcp', 'reservations', id, 'segment' },
				'references unknown segment ' .. tostring(r.segment))
		end
		if r.interface ~= nil and not has(intent.interfaces, r.interface) then
			return nil, err({ 'net', 'dhcp', 'reservations', id, 'interface' },
				'references unknown interface ' .. tostring(r.interface))
		end
	end
	return true, nil
end

local function segment_ranges(seg)
	return ((seg.addressing or {}).ipv4 or {}).reserved_ranges or {}
end

-- Check that reserved ranges are ordered and fit inside a static segment subnet,
-- excluding network, router and broadcast addresses. Reject interface addressing
-- overrides, overlapping ranges, and conflicts with DHCP pools or reservations.
local function validate_reserved_ranges(intent)
	for id, seg in pairs(intent.segments) do
		local ranges = segment_ranges(seg)
		if next(ranges) ~= nil then
			local path = { 'net', 'segments', id, 'addressing', 'ipv4' }
			local spec = seg.addressing.ipv4
			local subnet = ipv4.parse_cidr(spec.cidr)
			if not subnet or (spec.mode or spec.proto or 'static') ~= 'static' then
				return nil, err(path, 'reserved ranges require a static IPv4 CIDR')
			end
			for ifid, iface in pairs(intent.interfaces) do
				local attached = iface.segment == id
				for _, ref in ipairs(iface.segments or {}) do attached = attached or ref == id end
				if attached and next(iface.addressing or {}) ~= nil then
					return nil, err(path,
						'reserved ranges do not support interface addressing overrides (' .. ifid .. ')')
				end
			end
			local network = ipv4.address_to_integer(subnet.network)
			local broadcast = ipv4.address_to_integer(subnet.broadcast)
			local router = ipv4.address_to_integer(subnet.address)
			local first_dhcp, last_dhcp
			local dh = seg.dhcp or {}
			if dh.enabled == true then
				local defaults = intent.dhcp.defaults or {}
				local start = dh.start or dh.range_start or defaults.start or 100
				local limit = dh.limit or dh.range_limit or defaults.limit or 150
				if type(start) ~= 'number' or start % 1 ~= 0 or start < 0
					or type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 then
					return nil, err({ 'net', 'segments', id, 'dhcp' },
						'start and limit must be non-negative/positive integers')
				end
				first_dhcp, last_dhcp = network + start, network + start + limit - 1
				if first_dhcp <= network or last_dhcp >= broadcast then
					return nil, err({ 'net', 'segments', id, 'dhcp' },
						'dynamic DHCP pool must fit within usable subnet addresses')
				end
			end
			local seen = {}
			for rid, range in pairs(ranges) do
				local rpath = { schema.path(path), 'reserved_ranges', rid }
				local first, last = ipv4.address_to_integer(range.from), ipv4.address_to_integer(range.to)
				if first > last then return nil, err(rpath, 'range start must not exceed end') end
				if not ipv4.range_inside(spec.cidr, range.from, range.to) then
					return nil, err(rpath, 'range is outside subnet')
				end
				if first <= network or last >= broadcast or (first <= router and router <= last) then
					return nil, err(rpath, 'range must exclude network, router and broadcast addresses')
				end
				if first_dhcp and first <= last_dhcp and first_dhcp <= last then
					return nil, err(rpath, 'range overlaps dynamic DHCP pool')
				end
				for _, other in ipairs(seen) do
					if ipv4.ranges_overlap(range.from, range.to, other.from, other.to) then
						return nil, err(rpath, 'reserved ranges overlap')
					end
				end
				seen[#seen + 1] = range
				for reservation_id, reservation in pairs(intent.dhcp.reservations or {}) do
					if not schema.is_plain_table(reservation) then
						return nil, err({ 'net', 'dhcp', 'reservations', reservation_id },
							'must be a reservation table')
					end
					local address = ipv4.address_to_integer(reservation.ip or reservation.address)
					-- Check every reservation: segment/interface hints are not allocation barriers.
					if address and address >= first and address <= last then
						return nil, err({ 'net', 'dhcp', 'reservations', reservation_id },
							'address is in manual-only reserved range ' .. id .. '.' .. rid)
					end
				end
			end
		end
	end
	return true
end

-- Check that discovery references existing source/destination segments and a
-- reserved range on the source. Reject the source as a destination, repeated
-- destinations and duplicate service types within a policy.
local function validate_discovery(intent)
	for id, policy in pairs(intent.dns.service_discovery or {}) do
		local path = { 'net', 'dns', 'service_discovery', id }
		local source = intent.segments[policy.source_segment]
		if not source then
			return nil, err({ schema.path(path), 'source_segment' },
			'references unknown segment ' .. policy.source_segment)
		end
		if not segment_ranges(source)[policy.address_range] then
			return nil, err({ schema.path(path), 'address_range' },
				'references unknown reserved range ' .. policy.address_range)
		end
		local seen = {}
		for _, destination in ipairs(policy.advertise_to) do
			if not intent.segments[destination] then
				return nil, err({ schema.path(path), 'advertise_to' },
				'references unknown segment ' .. destination)
			end
			if destination == policy.source_segment then
				return nil, err(path,
				'source segment cannot also be a destination')
			end
			if seen[destination] then return nil, err(path, 'duplicate destination segment ' .. destination) end
			seen[destination] = true
		end
		local service_types = {}
		for _, service in pairs(policy.services) do
			if service_types[service.type] then return nil, err(path, 'duplicate service type ' .. service.type) end
			service_types[service.type] = true
		end
	end
	return true
end

-- Associate access rules by consumer/device zones and advertised protocol/port,
-- never by a printer name or a magic rule ID. Discovery does not create access.
local function validate_shared_access(intent)
	for rid, rule in pairs(intent.firewall.rules or {}) do
		if (rule.target or 'ACCEPT') == 'ACCEPT' and rule.dest and rule.family ~= 'ipv6' then
			local allowed = {}
			for _, policy in pairs(intent.dns.service_discovery or {}) do
				local source = intent.segments[policy.source_segment]
				local source_zone = source.firewall.zone
				local matches_zones = false
				for _, destination in ipairs(policy.advertise_to) do
					local dest_zone = intent.segments[destination].firewall.zone
					matches_zones = matches_zones or (dest_zone ~= nil and source_zone ~= nil
						and (rule.src == dest_zone or rule.src == '*') and (rule.dest == source_zone or rule.dest == '*'))
				end
				if matches_zones then
					for _, service in pairs(policy.services) do
						for _, port in ipairs(service.ports) do
							if firewall_values.protocol_matches(rule.proto, service.protocol)
								and firewall_values.port_matches(rule.dest_port, port) then
								allowed[#allowed + 1] = segment_ranges(source)[policy.address_range]
							end
						end
					end
				end
			end
			if #allowed > 0 then
				local path = { 'net', 'firewall', 'rules', rid, 'dest_ip' }
				local addresses = firewall_values.values(rule.dest_ip)
				if #addresses == 0 then
					return nil, err(path,
					'shared-device access requires explicit destinations in the reserved range')
				end
				for _, value in ipairs(addresses) do
					local address = firewall_values.address(value)
					local inside = false
					for _, range in ipairs(allowed) do
						inside = inside or (address.family == 'ipv4' and not address.invert
							and address.first >= ipv4.address_to_integer(range.from) and address.last <= ipv4.address_to_integer(range.to))
					end
					if not inside then
						return nil, err(path,
						'shared-device destination must be contained in the declared reserved range')
					end
				end
			end
		end
	end
	return true
end

function M.validate(intent)
	local ok, e = validate_interfaces(intent); if not ok then return nil, e end
	ok, e = validate_segments(intent); if not ok then return nil, e end
	ok, e = validate_wan(intent); if not ok then return nil, e end
	ok, e = validate_routing(intent); if not ok then return nil, e end
	ok, e = validate_firewall(intent); if not ok then return nil, e end
	ok, e = validate_dhcp(intent); if not ok then return nil, e end
	ok, e = validate_reserved_ranges(intent); if not ok then return nil, e end
	ok, e = validate_discovery(intent); if not ok then return nil, e end
	ok, e = validate_shared_access(intent); if not ok then return nil, e end
	return true, nil
end

return M
