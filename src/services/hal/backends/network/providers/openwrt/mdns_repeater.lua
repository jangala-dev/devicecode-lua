-- Translate generic discovery intent to OpenWrt's mdns_repeater UCI package.
-- This backend filters packet sources, not DNS-SD records or service endpoints.
local M = {}

local function ipv4_number(address)
	if type(address) ~= 'string' then return nil end
	local a, b, c, d = address:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	local n = 0
	for _, octet in ipairs({ a, b, c, d }) do
		octet = tonumber(octet)
		if not octet or octet > 255 then return nil end
		n = n * 256 + octet
	end
	return d and n or nil
end

local function ipv4_text(n)
	return string.format('%d.%d.%d.%d', math.floor(n / 16777216), math.floor(n / 65536) % 256,
		math.floor(n / 256) % 256, n % 256)
end

local function subnet(cidr)
	if type(cidr) ~= 'string' then return nil end
	local address, prefix = cidr:match('^([^/]+)/(%d+)$')
	local n = ipv4_number(address)
	prefix = tonumber(prefix)
	if not n or not prefix or prefix > 32 then return nil end
	local size = 2 ^ (32 - prefix)
	local first = math.floor(n / size) * size
	return ipv4_text(first) .. '/' .. prefix, first, first + size - 1
end

local function data_device(intent, devices, id)
	local segment = (intent.segments or {})[id]
	local candidates = devices[id] or {}
	if not segment or segment.enabled == false or #candidates ~= 1 then
		return nil, 'discovery segment ' .. tostring(id) .. ' requires one enabled Linux data device'
	end
	local candidate = candidates[1]
	if type(candidate.device) ~= 'string' or candidate.device == '' then
		return nil, 'discovery segment ' .. id .. ' has no Linux data device'
	end
	local cidr, first, last = subnet(candidate.cidr)
	if not cidr then return nil, 'discovery segment ' .. id .. ' requires a known IPv4 subnet' end
	return { device = candidate.device, cidr = cidr, first = first, last = last }
end

function M.capabilities()
	return { directional = false, range_filter = 'source_ip', service_filter = false, port_filter = false }
end

-- A single repeater shares every permitted packet across all its interfaces.
-- Reject multiple policies/destinations rather than merging them and exposing
-- services between networks that the individual policies did not connect.
function M.build_changes(intent, devices)
	local policies = (intent.dns or {}).service_discovery or {}
	local policy, policy_id
	for id, item in pairs(policies) do
		if item.enabled ~= false then
			if policy then return nil, 'mdns-repeater supports only one enabled discovery policy' end
			policy, policy_id = item, id
		end
	end
	local changes = { { op = 'set', config = 'mdns_repeater', section = 'main', option = 'mdns_repeater' } }
	local function set(option, value)
		changes[#changes + 1] = { op = 'set', config = 'mdns_repeater', section = 'main', option = option, value = value }
	end
	local plan = {
		status = policy and 'implemented' or 'not_configured', backend = 'mdns_repeater',
		capabilities = M.capabilities(),
	}
	set('enabled', policy and '1' or '0')
	if policy then
		if policy.family ~= 'ipv4' then return nil, 'mdns-repeater discovery supports only IPv4' end
		if #(policy.advertise_to or {}) ~= 1 then
			return nil, 'mdns-repeater supports only one discovery destination'
		end
		local source, err = data_device(intent, devices, policy.source_segment)
		if not source then return nil, err end
		local destination, derr = data_device(intent, devices, policy.advertise_to[1])
		if not destination then return nil, derr end
		if source.device == destination.device or (source.first <= destination.last and destination.first <= source.last) then
			return nil, 'mdns-repeater requires distinct devices with non-overlapping IPv4 subnets'
		end
		local spec = ((intent.segments[policy.source_segment].addressing or {}).ipv4 or {})
		local range = (spec.reserved_ranges or {})[policy.address_range] or {}
		local first, last = ipv4_number(range.from), ipv4_number(range.to)
		if not first or not last or first > last or first <= source.first or last >= source.last then
			return nil, 'mdns-repeater range must be inside the source IPv4 subnet'
		end
		-- Upstream accepts at most 16 whitelist entries. Reserve one for client queries.
		if last - first + 1 > 15 then
			return nil, 'mdns-repeater supports at most 15 shared addresses with one client subnet'
		end
		local whitelist = {}
		for address = first, last do whitelist[#whitelist + 1] = ipv4_text(address) .. '/32' end
		whitelist[#whitelist + 1] = destination.cidr
		set('interface', { source.device, destination.device })
		set('whitelist', whitelist)
		plan.policy = policy_id
		plan.interfaces = { source.device, destination.device }
		plan.whitelist = whitelist
		plan.limitations = {
			'Filters packet source IPv4, not advertised endpoint addresses.',
			'Service type and port constraints are not enforced by discovery; firewall access remains separate.',
			'Client queries and advertisements are both repeated to the source network.',
		}
	end
	return { changes = changes, sections = { main = true }, plan = plan }
end

-- Refuse the stock init script when enabled: it silently ignores the whitelist.
-- Missing packages remain harmless when discovery is disabled. The firmware's
-- apply command validates first and waits for the supervised process to start.
function M.activation_command()
	return { '/bin/sh', '-c', [[
if [ "$(uci -q get mdns_repeater.main.enabled)" = "1" ]; then
    if [ "$(/etc/init.d/mdns-repeater capabilities 2>/dev/null)" != "source-whitelist-v1" ]; then
        echo 'mdns-repeater requires the source-whitelist-v1 firmware init script' >&2
        exit 1
    fi
    /etc/init.d/mdns-repeater apply
elif [ -x /etc/init.d/mdns-repeater ]; then
    /etc/init.d/mdns-repeater stop || ! /etc/init.d/mdns-repeater running
fi
]], wait = true }
end

function M.snapshot(package)
	local main = (package or {}).main or {}
	return {
		configured = main.enabled == '1', backend = 'mdns_repeater',
		interfaces = main.interface or {}, whitelist = main.whitelist or {}, capabilities = M.capabilities(),
	}
end

return M
