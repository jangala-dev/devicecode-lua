-- Pure IPv4 arithmetic for NET validation. No host or backend dependencies.
-- Parsers return a value or nil, error. Predicates return boolean or nil, error.
local M = {}

function M.parse_address(address)
	if type(address) ~= 'string' then return nil, 'must be an IPv4 address' end
	local a, b, c, d = address:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	if not a then return nil, 'must be an IPv4 address' end
	local octets = { a, b, c, d }
	for i, value in ipairs(octets) do
		if #value > 3 or (#value > 1 and value:sub(1, 1) == '0') or tonumber(value) > 255 then
			return nil, 'must be an IPv4 address with decimal octets in 0..255'
		end
		octets[i] = tonumber(value)
	end
	return octets
end

function M.address_to_integer(address)
	local octets, err = M.parse_address(address)
	if not octets then return nil, err end
	local n = 0
	for _, octet in ipairs(octets) do n = n * 256 + octet end
	return n
end

local function format_address(n)
	local octets = {}
	for i = 4, 1, -1 do
		octets[i] = tostring(n % 256)
		n = math.floor(n / 256)
	end
	return table.concat(octets, '.')
end

-- The record retains the host address as well as the subnet boundaries.
function M.parse_cidr(cidr)
	if type(cidr) ~= 'string' then return nil, 'must be an IPv4 CIDR' end
	local address, bits = cidr:match('^([^/]+)/(%d+)$')
	local n = M.address_to_integer(address)
	local prefix = tonumber(bits)
	if not n or not prefix or prefix > 32 then return nil, 'must be an IPv4 CIDR with prefix 0..32' end
	local size = 2 ^ (32 - prefix)
	local first = math.floor(n / size) * size
	return {
		address = address, prefix = prefix,
		network = format_address(first), broadcast = format_address(first + size - 1),
	}
end

function M.network_address(cidr)
	local parsed, err = M.parse_cidr(cidr)
	if not parsed then return nil, err end
	return parsed.network
end

function M.broadcast_address(cidr)
	local parsed, err = M.parse_cidr(cidr)
	if not parsed then return nil, err end
	return parsed.broadcast
end

function M.contains(cidr, address)
	local parsed, err = M.parse_cidr(cidr)
	if not parsed then return nil, err end
	local n, aerr = M.address_to_integer(address)
	if not n then return nil, aerr end
	return n >= M.address_to_integer(parsed.network) and n <= M.address_to_integer(parsed.broadcast)
end

local function range(first, last)
	local a, aerr = M.address_to_integer(first)
	if not a then return nil, nil, aerr end
	local b, berr = M.address_to_integer(last)
	if not b then return nil, nil, berr end
	if a > b then return nil, nil, 'range start must not exceed end' end
	return a, b
end

function M.range_inside(cidr, first, last)
	local a, _, err = range(first, last)
	if not a then return nil, err end
	local inside, cerr = M.contains(cidr, first)
	if inside == nil then return nil, cerr end
	return inside and M.contains(cidr, last)
end

function M.ranges_overlap(first_a, last_a, first_b, last_b)
	local a, b, err = range(first_a, last_a)
	if not a then return nil, err end
	local c, d, berr = range(first_b, last_b)
	if not c then return nil, berr end
	return a <= d and c <= b
end

return M
