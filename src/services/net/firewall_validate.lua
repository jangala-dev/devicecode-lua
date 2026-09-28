-- Validation of semantic firewall rule values. Does not rewrite rule syntax.
local schema = require 'services.net.schema'
local ipv4 = require 'services.net.ipv4'
local M = {}

-- Accept scalar/list and space-separated forms already used by NET configs.
function M.values(value)
	if value == nil then return {} end
	local input = type(value) == 'table' and value or { value }
	if not schema.is_plain_table(input) then return nil end
	local out, count = {}, 0
	for index, item in pairs(input) do
		if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > #input then return nil end
		if type(item) ~= 'string' and type(item) ~= 'number' then return nil end
		count = count + 1
	end
	if count == 0 or count ~= #input then return nil end
	for _, item in ipairs(input) do
		local found = false
		for token in tostring(item):gsub('!%s+', '!'):gmatch('%S+') do
			out[#out + 1], found = token, true
		end
		if not found then return nil end
	end
	return out
end

local function uninvert(value)
	return value:gsub('^!', ''), value:sub(1, 1) == '!'
end

local function valid_ipv6(address)
	if not address:find(':', 1, true) then return false end
	-- An embedded IPv4 tail occupies two 16-bit groups.
	if address:find('.', 1, true) then
		local head, tail = address:match('^(.*:)([^:]+)$')
		if not head or not ipv4.parse_address(tail) then return false end
		address = head .. '0:0'
	end
	if address:find('[^%x:]') then return false end
	local left, right = address:match('^(.-)::(.-)$')
	if left and right:find('::', 1, true) then return false end
	local function groups(part)
		if part == '' then return 0 end
		if part:sub(1, 1) == ':' or part:sub(-1) == ':' then return nil end
		local count = 0
		for group in part:gmatch('[^:]+') do
			if #group > 4 then return nil end
			count = count + 1
		end
		return count
	end
	if left then
		local a, b = groups(left), groups(right)
		return a ~= nil and b ~= nil and a + b < 8
	end
	return groups(address) == 8
end

function M.address(value)
	local text, invert = uninvert(value)
	local address, prefix = text:match('^([^/]+)/(%d+)$')
	if not address then address = text end
	if address:find(':', 1, true) then
		if not valid_ipv6(address) or (prefix and tonumber(prefix) > 128) then return nil end
		return { family = 'ipv6', invert = invert }
	end
	local parsed = ipv4.parse_cidr(address .. '/' .. (prefix or '32'))
	if not parsed then return nil end
	return {
		family = 'ipv4', invert = invert,
		first = ipv4.address_to_integer(parsed.network), last = ipv4.address_to_integer(parsed.broadcast),
	}
end

function M.port(value)
	local text, invert = uninvert(value)
	local first, last = text:match('^(%d+)[%-:](%d+)$')
	if not first then first, last = text:match('^(%d+)$'), text:match('^(%d+)$') end
	first, last = tonumber(first), tonumber(last)
	if not first or first < 1 or last > 65535 or first > last then return nil end
	return { first = first, last = last, invert = invert }
end

local PROTOCOLS = {}
local protocol_names = 'all any tcp udp tcpudp icmp icmpv6 ipv6-icmp igmp esp ah gre sctp dccp udplite ipip ipv6 '
	.. 'ipv6-route ipv6-frag ipv6-nonxt ipv6-opts ospf vrrp l2tp pim ip encap rsvp'
for name in protocol_names:gmatch('%S+') do
	PROTOCOLS[name] = true
end
local TARGETS = { ACCEPT = true, REJECT = true, DROP = true, NOTRACK = true, HELPER = true, MARK = true, DSCP = true }
local FAMILIES = { ipv4 = true, ipv6 = true, any = true }

local function valid_protocol(value)
	local text = uninvert(value)
	local n = text:match('^%d+$') and tonumber(text)
	return PROTOCOLS[text] or (n ~= nil and n >= 0 and n <= 255)
end

function M.rule(rule, zones, path)
	if not schema.is_plain_table(rule) then return nil, schema.err(path, 'must be a rule table') end
	for _, field in ipairs({ 'src', 'dest' }) do
		local zone = rule[field]
		if zone ~= nil and (type(zone) ~= 'string' or (zone ~= '*' and not zones[zone])) then
			return nil, schema.err({ schema.path(path), field }, 'references unknown firewall zone ' .. tostring(zone))
		end
	end
	if rule.family ~= nil and not FAMILIES[rule.family] then
		return nil, schema.err({ schema.path(path), 'family' }, 'must be ipv4, ipv6 or any')
	end
	if rule.target ~= nil and not TARGETS[rule.target] then
		return nil, schema.err({ schema.path(path), 'target' }, 'unsupported rule target')
	end
	for _, field in ipairs({ 'proto', 'src_ip', 'dest_ip', 'src_port', 'dest_port' }) do
		local values = M.values(rule[field])
		if not values then
			return nil, schema.err({ schema.path(path), field }, 'must be a value or non-empty array of values')
		end
		for _, value in ipairs(values) do
			local valid
			if field == 'proto' then valid = valid_protocol(value)
			elseif field == 'src_port' or field == 'dest_port' then valid = M.port(value)
			else
				valid = M.address(value)
				if valid and rule.family and rule.family ~= 'any' and valid.family ~= rule.family then valid = nil end
			end
			if not valid then return nil, schema.err({ schema.path(path), field }, 'invalid value ' .. value) end
		end
	end
	return true
end

function M.protocol_matches(value, protocol)
	local values = M.values(value)
	if #values == 0 then return protocol == 'tcp' or protocol == 'udp' end
	local positive, matched = false, false
	for _, entry in ipairs(values) do
		local text, invert = uninvert(entry)
		local hit = text == protocol or text == 'all' or text == 'any' or text == 'tcpudp'
			or (text == '6' and protocol == 'tcp') or (text == '17' and protocol == 'udp')
		if invert and hit then return false end
		if not invert then positive, matched = true, matched or hit end
	end
	return not positive or matched
end

function M.port_matches(value, port)
	local values = M.values(value)
	if #values == 0 then return true end
	local positive, matched = false, false
	for _, entry in ipairs(values) do
		local range = M.port(entry)
		local hit = port >= range.first and port <= range.last
		if range.invert and hit then return false end
		if not range.invert then positive, matched = true, matched or hit end
	end
	return not positive or matched
end

return M
