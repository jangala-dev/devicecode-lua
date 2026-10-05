local ipv4 = require 'services.net.ipv4'
local tests = {}
local function eq(a, b) assert(a == b, 'expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

function tests.test_decimal_address_boundaries()
	eq(ipv4.address_to_integer('0.0.0.0'), 0)
	eq(ipv4.address_to_integer('255.255.255.255'), 4294967295)
	eq(ipv4.address_to_integer('128.0.0.0'), 2147483648)
	local octets = assert(ipv4.parse_address('172.28.8.250'))
	eq(octets[1], 172); eq(octets[4], 250)
end

function tests.test_rejects_malformed_addresses()
	for _, value in ipairs({ '', '1.2.3', '1.2.3.4.5', '256.1.1.1', '-1.2.3.4', '1.2.3.4 ',
		'01.2.3.4', '1e2.2.3.4', '::1', '1.2.3.4/24', false, 123, {} }) do
		local parsed, err = ipv4.parse_address(value)
		eq(parsed, nil); assert(type(err) == 'string')
	end
	eq(ipv4.parse_address(nil), nil)
end

function tests.test_cidr_host_bits_and_extreme_prefixes()
	local parsed = assert(ipv4.parse_cidr('172.28.9.123/23'))
	eq(parsed.address, '172.28.9.123'); eq(parsed.prefix, 23)
	eq(parsed.network, '172.28.8.0'); eq(parsed.broadcast, '172.28.9.255')
	eq(ipv4.network_address('172.28.8.1/0'), '0.0.0.0')
	eq(ipv4.broadcast_address('172.28.8.1/0'), '255.255.255.255')
	eq(ipv4.network_address('172.28.8.251/31'), '172.28.8.250')
	eq(ipv4.broadcast_address('172.28.8.251/31'), '172.28.8.251')
	eq(ipv4.network_address('172.28.8.250/32'), '172.28.8.250')
	eq(ipv4.broadcast_address('172.28.8.250/32'), '172.28.8.250')
	for _, value in ipairs({ '1.2.3.4', '1.2.3.4/33', '1.2.3.4/-1', '1.2.3.4/2.4', '1.2.3.4/24/x', 'x/24' }) do
		eq(ipv4.parse_cidr(value), nil)
	end
end

function tests.test_containment_and_inclusive_overlap()
	eq(ipv4.contains('172.28.8.1/24', '172.28.8.254'), true)
	eq(ipv4.contains('172.28.8.1/24', '172.28.9.1'), false)
	eq(ipv4.range_inside('172.28.8.1/24', '172.28.8.250', '172.28.8.254'), true)
	eq(ipv4.range_inside('172.28.8.1/24', '172.28.8.250', '172.28.9.1'), false)
	eq(ipv4.ranges_overlap('1.2.3.10', '1.2.3.20', '1.2.3.20', '1.2.3.30'), true)
	eq(ipv4.ranges_overlap('1.2.3.10', '1.2.3.20', '1.2.3.21', '1.2.3.30'), false)
	eq(ipv4.ranges_overlap('1.2.3.10', '1.2.3.30', '1.2.3.15', '1.2.3.20'), true)
	eq(ipv4.range_inside('1.2.3.0/24', '1.2.3.20', '1.2.3.10'), nil)
	eq(ipv4.ranges_overlap('bad', '1.2.3.20', '1.2.3.21', '1.2.3.30'), nil)
	eq(ipv4.contains('bad', '1.2.3.4'), nil)
end
return tests
