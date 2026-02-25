-- services/net/compiler.lua
--
-- Compile pre-net config into a strict desired state bundle for HAL.
-- Pure, non-yielding, side-effect free.
--
-- Returns:
--   desired_table, nil
-- or
--   nil, diag_table  { code=string, path=Topic, message=string }
--
-- Conventions:
--   * Missing fields imply defaults (compiler generally omits nil fields).
--   * Output is intended for "replace/reconcile" application by HAL.

local M = {}

local function diag(code, path, message)
	return { code = code, path = path or {}, message = message or code }
end

local function is_plain_table(x) return type(x) == 'table' and getmetatable(x) == nil end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function get_tbl(t, k)
	local v = t and t[k] or nil
	return is_plain_table(v) and v or nil
end

local function get_bool(t, k)
	local v = t and t[k] or nil
	if v == nil then return nil end
	return not not v
end

local function get_num(t, k)
	local v = t and t[k] or nil
	if v == nil then return nil end
	return (type(v) == 'number') and v or nil
end

local function get_str(t, k)
	local v = t and t[k] or nil
	if v == nil then return nil end
	return (type(v) == 'string') and v or nil
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

-- IPv4 netmask ("255.255.255.0") -> prefix (24). Validates contiguity.
local MASK_BITS = {
	[255] = 8, [254] = 7, [252] = 6, [248] = 5, [240] = 4, [224] = 3, [192] = 2, [128] = 1, [0] = 0,
}
local function netmask_to_prefix(mask)
	if type(mask) ~= 'string' then return nil end
	local a, b, c, d = mask:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if not (a and b and c and d) then return nil end
	if a < 0 or a > 255 or b < 0 or b > 255 or c < 0 or c > 255 or d < 0 or d > 255 then return nil end

	local octs = { a, b, c, d }
	local seen_partial = false
	local pfx = 0

	for i = 1, 4 do
		local ob = MASK_BITS[octs[i]]
		if ob == nil then return nil end
		if seen_partial and ob ~= 0 then return nil end
		if ob ~= 8 then seen_partial = true end
		pfx = pfx + ob
	end

	return pfx
end

local function is_ipv4(s)
	return type(s) == 'string' and s:match('^%d+%.%d+%.%d+%.%d+$') ~= nil
end

local function normalise_route_target(target)
	if type(target) ~= 'string' or target == '' then return nil end
	if target:find('/', 1, true) then
		return target
	end
	-- Canonicalise host route when no prefix is given.
	if is_ipv4(target) then
		return target .. '/32'
	end
	-- Leave other forms as-is (backend may reject if unsupported).
	return target
end

local function join_host_sets(list)
	-- list is an array of strings; return stable id like "ads_adult" or "plain".
	if not list or #list == 0 then return 'plain' end
	local parts = {}
	for i = 1, #list do parts[i] = tostring(list[i]) end
	table.sort(parts)
	return table.concat(parts, '_')
end

local function uniq_sorted(list)
	local seen, out = {}, {}
	for i = 1, #(list or {}) do
		local v = list[i]
		if type(v) == 'string' and v ~= '' and not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
	table.sort(out)
	return out
end

-- Resolve per-net "firewall.zone" by looking at net record first, then profile.
local function resolve_zone(net_rec, prof_rec)
	local z = get_tbl(net_rec, 'firewall')
	if z and type(z.zone) == 'string' and z.zone ~= '' then return z.zone end
	local pz = prof_rec and get_tbl(prof_rec, 'firewall') or nil
	if pz and type(pz.zone) == 'string' and pz.zone ~= '' then return pz.zone end
	return nil
end

local function resolve_multiwan(net_rec, prof_rec)
	local mw = net_rec and net_rec.multiwan
	if mw ~= nil then return mw end
	if prof_rec and prof_rec.multiwan ~= nil then return prof_rec.multiwan end
	return nil
end

local function resolve_shaping(net_rec, prof_rec)
	local sh = net_rec and net_rec.shaping
	if sh ~= nil then return sh end
	if prof_rec and prof_rec.shaping ~= nil then return prof_rec.shaping end
	return nil
end

local function compile_links_and_nets(pre, rev, gen)
	local network = get_tbl(pre, 'network') or {}
	local nets_in = get_tbl(network, 'nets') or {}
	local profiles = get_tbl(pre, 'profiles') or {}

	local links = {}
	local nets_out = {}

	for _, net_id in ipairs(sorted_keys(nets_in)) do
		local nrec = nets_in[net_id]
		if not is_plain_table(nrec) then
			return nil, diag('invalid_net', { 'net', 'network', 'nets', net_id }, 'net record must be a table')
		end

		local profile_name = (type(nrec.profile) == 'string') and nrec.profile or nil
		local prof = profile_name and profiles[profile_name] or nil
		if profile_name and not is_plain_table(prof) then
			return nil,
				diag('unknown_profile', { 'net', 'profiles', profile_name },
					'unknown profile: ' .. tostring(profile_name))
		end

		-- Device
		local dev = get_tbl(nrec, 'device') or {}
		local dev_kind = get_str(dev, 'kind') or 'raw'
		local ifnames = dev.ifnames
		if ifnames ~= nil and type(ifnames) ~= 'table' then
			return nil,
				diag('invalid_ifnames', { 'net', 'network', 'nets', net_id, 'device', 'ifnames' },
					'ifnames must be an array')
		end

		local device_out

		if dev_kind == 'bridge' then
			local link_name = 'br-' .. tostring(net_id)
			local ports = {}
			for i = 1, #(ifnames or {}) do
				if type(ifnames[i]) == 'string' and ifnames[i] ~= '' then
					ports[#ports + 1] = ifnames[i]
				end
			end
			if #ports == 0 then
				-- You may choose to allow empty bridges when bridge_empty=true. Here we honour input.
				local be = get_bool(dev, 'bridge_empty')
				if not be then
					return nil,
						diag('bridge_no_ports', { 'net', 'network', 'nets', net_id, 'device' },
							'bridge requires ports unless bridge_empty=true')
				end
			end

			links[link_name] = {
				kind              = 'bridge',
				ports             = ports,

				bridge_empty      = get_bool(dev, 'bridge_empty') or false,
				vlan_filtering    = false,
				igmp_snooping     = false,
				multicast_querier = false,
				stp               = false,

				rxpause           = nil,
				txpause           = nil,
				autoneg           = nil,
				speed             = nil,
				duplex            = nil,
				macaddr           = nil,
			}

			device_out = { ref = link_name }
		else
			-- raw device
			local modem_id = (type(nrec.modem_id) == 'string') and nrec.modem_id or nil
			if modem_id then
				device_out = { ifname = '@modem.' .. modem_id }
			else
				local ifname = (ifnames and ifnames[1]) or nil
				if type(ifname) ~= 'string' or ifname == '' then
					-- allow empty ifnames in pre-config (e.g. placeholder), but then output will be explicit nil
					ifname = nil
				end
				device_out = { ifname = ifname }
			end
		end

		-- IPv4
		local ipv4 = get_tbl(nrec, 'ipv4') or (prof and get_tbl(get_tbl(prof, 'network') or {}, 'ipv4')) or nil
		local proto = (ipv4 and get_str(ipv4, 'proto')) or 'static'
		local v4 = nil
		local peerdns = nil

		if proto == 'static' then
			local ip = ipv4 and get_str(ipv4, 'ip_address') or nil
			local nm = ipv4 and get_str(ipv4, 'netmask') or nil
			if ip and nm then
				local pfx = netmask_to_prefix(nm)
				if not pfx then
					return nil,
						diag('bad_netmask', { 'net', 'network', 'nets', net_id, 'ipv4', 'netmask' },
							'invalid netmask: ' .. tostring(nm))
				end
				v4 = { addr = ip, prefix = pfx, gw = nil }
			elseif net_id == 'loopback' then
				-- Allow loopback to be pre-specified exactly as in example.
				v4 = { addr = '127.0.0.1', prefix = 8, gw = nil }
			else
				-- Permit missing static fields; HAL/backend may reject later if required.
				v4 = nil
			end
		elseif proto == 'dhcp' then
			v4 = nil
			if ipv4 and ipv4.peerdns ~= nil then
				peerdns = not not ipv4.peerdns
			end
		else
			return nil,
				diag('bad_proto', { 'net', 'network', 'nets', net_id, 'ipv4', 'proto' },
					'unsupported proto: ' .. tostring(proto))
		end

		-- Net output
		nets_out[net_id] = {
			proto      = proto,
			device     = device_out,

			auto       = true,
			disabled   = false,
			force_link = (net_id == 'loopback') or (proto == 'static') or nil,

			v4         = v4,

			dns        = nil,
			peerdns    = peerdns,
			metric     = nil,

			ipv6       = nil,
			ip6assign  = nil,

			mtu        = nil,
			ip4table   = nil,
			ip6table   = nil,
		}
	end

	return {
		rev     = rev,
		globals = shallow_copy(get_tbl(network, 'globals') or {}),
		links   = links,
		nets    = nets_out,
		routes  = {}, -- filled elsewhere
	}, nil
end

local function is_ipv4_or_cidr(s)
	if type(s) ~= 'string' then return false end
	local ip = s:match('^([^/]+)') or s
	return ip:match('^%d+%.%d+%.%d+%.%d+$') ~= nil
end

local function compile_routes(pre)
	local out = {}
	local routes = get_tbl(pre, 'routes') or {}
	local static = routes.static
	if static ~= nil and type(static) ~= 'table' then
		return nil, diag('bad_routes', { 'net', 'routes', 'static' }, 'routes.static must be an array')
	end
	for i = 1, #(static or {}) do
		local r = static[i]
		if not is_plain_table(r) then
			return nil, diag('bad_route', { 'net', 'routes', 'static', i }, 'route must be a table')
		end
		local target = normalise_route_target(r.target)
		local iface  = (type(r.interface) == 'string') and r.interface or nil
		if not target or not iface then
			return nil, diag('bad_route', { 'net', 'routes', 'static', i }, 'route requires target and interface')
		end
		out[#out + 1] = {
			family = is_ipv4_or_cidr(target) and 'ipv4' or 'ipv6',
			target = target,
			net    = iface,
			via    = nil,
		}
	end
	return out, nil
end

local function compile_addressing(pre, nets_in, profiles)
	local dns_in   = get_tbl(pre, 'dns') or {}
	local dhcp_in  = get_tbl(pre, 'dhcp') or {}

	local upstream = dns_in.upstream_servers
	if upstream ~= nil and type(upstream) ~= 'table' then
		return nil, diag('bad_dns', { 'net', 'dns', 'upstream_servers' }, 'upstream_servers must be an array')
	end
	local upstream_servers = {}
	for i = 1, #(upstream or {}) do
		if type(upstream[i]) == 'string' and upstream[i] ~= '' then
			upstream_servers[#upstream_servers + 1] = upstream[i]
		end
	end

	local cache_size = dns_in.default_cache_size
	if cache_size ~= nil and type(cache_size) ~= 'number' then
		return nil, diag('bad_dns', { 'net', 'dns', 'default_cache_size' }, 'default_cache_size must be a number')
	end

	-- Gather host_sets used by DHCP pools from nets' dns_server.default_hosts.
	local hostset_to_profile = {}
	local profiles_out = {}

	local function ensure_dns_profile(host_sets)
		local hs = uniq_sorted(host_sets)
		local name = join_host_sets(hs)
		if hostset_to_profile[name] then return name end
		hostset_to_profile[name] = true
		profiles_out[name] = {
			domainneeded      = nil,
			boguspriv         = nil,
			authoritative     = nil,
			localservice      = nil,
			rebind_protection = nil,

			upstream_servers  = upstream_servers,
			cache_size        = cache_size,

			host_sets         = hs,
		}
		return name
	end

	-- Pools derive from networks with dhcp_server.enabled=true.
	local pools = {}
	for _, net_id in ipairs(sorted_keys(nets_in)) do
		local nrec = nets_in[net_id]
		local dh = get_tbl(nrec, 'dhcp_server')
		if dh and get_bool(dh, 'enabled') then
			local start = get_num(dh, 'range_skip')
			local limit = get_num(dh, 'range_extent')
			local leasetime = get_str(dh, 'lease_time')
			if not (start and limit and leasetime) then
				return nil,
					diag('bad_dhcp', { 'net', 'network', 'nets', net_id, 'dhcp_server' },
						'dhcp_server missing required fields')
			end

			local dns_server = get_tbl(nrec, 'dns_server') or {}
			local host_sets  = dns_server.default_hosts
			if host_sets ~= nil and type(host_sets) ~= 'table' then
				return nil,
					diag('bad_dns', { 'net', 'network', 'nets', net_id, 'dns_server', 'default_hosts' },
						'default_hosts must be an array')
			end

			local dns_profile = ensure_dns_profile(host_sets or {})

			pools[net_id] = {
				net         = net_id,
				start       = start,
				limit       = limit,
				leasetime   = leasetime,
				v4          = 'server',
				dns_profile = dns_profile,
			}
		end
	end

	-- Domains: passthrough array of {name, ip} (validation left to backend/compiler v2).
	local domains = {}
	local doms = dhcp_in.domains
	if doms ~= nil and type(doms) ~= 'table' then
		return nil, diag('bad_domains', { 'net', 'dhcp', 'domains' }, 'dhcp.domains must be an array')
	end
	for i = 1, #(doms or {}) do
		local d = doms[i]
		if is_plain_table(d) and type(d.name) == 'string' and d.name ~= '' then
			domains[#domains + 1] = { name = d.name, ip = d.ip }
		end
	end

	return {
		dns = profiles_out,
		pools = pools,
		reservations = {},
		domains = domains,
	}, nil
end

local function compile_firewall(pre, nets_in, profiles)
	local fw = get_tbl(pre, 'firewall') or {}
	local defaults = get_tbl(fw, 'defaults') or {}
	local zones_in = get_tbl(fw, 'zones') or {}
	local rules_in = fw.rules

	if rules_in ~= nil and type(rules_in) ~= 'table' then
		return nil, diag('bad_firewall', { 'net', 'firewall', 'rules' }, 'firewall.rules must be an array')
	end

	-- Assign nets to zones (from net record or profile).
	local zone_to_nets = {}
	for _, net_id in ipairs(sorted_keys(nets_in)) do
		local nrec = nets_in[net_id]
		local prof = nil
		if type(nrec.profile) == 'string' then prof = profiles[nrec.profile] end
		local zname = resolve_zone(nrec, prof)
		if zname then
			zone_to_nets[zname] = zone_to_nets[zname] or {}
			zone_to_nets[zname][#zone_to_nets[zname] + 1] = net_id
		end
	end
	for zname, list in pairs(zone_to_nets) do
		table.sort(list)
	end

	-- Zones
	local zones_out = {}
	local forwardings = {}

	for _, zname in ipairs(sorted_keys(zones_in)) do
		local zrec = zones_in[zname]
		if not is_plain_table(zrec) then
			return nil, diag('bad_zone', { 'net', 'firewall', 'zones', zname }, 'zone must be a table')
		end
		local zcfg = get_tbl(zrec, 'config') or {}
		local nets = zone_to_nets[zname] or {}

		zones_out[zname] = {
			input    = zcfg.input,
			output   = zcfg.output,
			forward  = zcfg.forward,
			masq     = get_bool(zcfg, 'masq') or false,
			mtu_fix  = get_bool(zcfg, 'mtu_fix') or false,
			networks = nets,
		}

		local fwd = zrec.forward_to
		if fwd ~= nil and type(fwd) == 'table' then
			for i = 1, #fwd do
				if type(fwd[i]) == 'string' and fwd[i] ~= '' then
					forwardings[#forwardings + 1] = { src = zname, dest = fwd[i] }
				end
			end
		end
	end

	-- Rules
	local rules_out = {}
	for i = 1, #(rules_in or {}) do
		local r = rules_in[i]
		if is_plain_table(r) then
			local cfg = get_tbl(r, 'config') or {}
			rules_out[#rules_out + 1] = {
				id        = r.id,
				name      = cfg.name,
				src       = cfg.src,
				dest      = cfg.dest,
				proto     = cfg.proto,
				src_port  = cfg.src_port,
				dest_port = cfg.dest_port,
				icmp_type = cfg.icmp_type,
				target    = cfg.target,
			}
		end
	end

	return {
		defaults    = shallow_copy(defaults),
		zones       = zones_out,
		forwardings = forwardings,
		rules       = rules_out,
	}, nil
end

local function compile_multiwan(pre, nets_in, profiles)
	local mw = get_tbl(pre, 'multiwan')
	if not mw then
		return nil, nil -- optional
	end

	local globals    = get_tbl(mw, 'globals') or {}
	local health     = get_tbl(mw, 'health') or {}

	local uplinks    = {}
	local members    = {}
	local member_ids = {}

	for _, net_id in ipairs(sorted_keys(nets_in)) do
		local nrec = nets_in[net_id]
		local prof = nil
		if type(nrec.profile) == 'string' then prof = profiles[nrec.profile] end
		local nmw = resolve_multiwan(nrec, prof)
		if nmw and is_plain_table(nmw) then
			local metric                = get_num(nmw, 'metric') or 1
			local dynw                  = get_bool(nmw, 'dynamic_weight')

			uplinks[net_id]             = {
				enabled        = true,
				family         = 'ipv4',
				net            = net_id,
				track          = get_str(health, 'track_method') or 'ping',
				reliability    = (get_num(health, 'down') and math.floor(get_num(health, 'down'))) or 2,
				interval       = (get_num(health, 'interval_s') and math.floor(get_num(health, 'interval_s'))) or 1,
				timeout        = (get_num(health, 'timeout_s') and math.floor(get_num(health, 'timeout_s'))) or 2,
				probe          = (type(health.track_ip) == 'table') and health.track_ip or nil,
				dynamic_weight = dynw,
			}

			local mid                   = string.format('%s_m%d_w1', net_id, math.floor(metric))
			members[mid]                = { uplink = net_id, metric = math.floor(metric), weight = 1 }
			member_ids[#member_ids + 1] = mid
		end
	end

	table.sort(member_ids)
	for i = 1, #member_ids do member_ids[i] = member_ids[i] end

	local policies = {
		default = {
			last_resort = 'unreachable',
			use = member_ids,
		},
	}

	local rules = {
		{ id = 'default', policy = 'default' },
	}

	return {
		globals  = {
			enabled   = get_bool(globals, 'enabled'),
			logging   = get_bool(globals, 'logging'),
			loglevel  = get_str(globals, 'loglevel'),
			mark_mask = get_str(globals, 'mark_mask'),
		},
		uplinks  = uplinks,
		members  = members,
		policies = policies,
		rules    = rules,
	}, nil
end

function M.compile(pre_net_data, opts)
	opts = opts or {}
	local rev = opts.rev
	local gen = opts.gen

	if type(rev) ~= 'number' then return nil, diag('bad_rev', { 'net', 'rev' }, 'rev must be a number') end
	if type(gen) ~= 'number' then gen = 0 end
	rev = math.floor(rev)
	gen = math.floor(gen)

	if not is_plain_table(pre_net_data) then
		return nil, diag('bad_config', { 'net', 'data' }, 'net data must be a table')
	end

	local schema = pre_net_data.schema
	if schema ~= nil and type(schema) == 'string' then
		-- Optional strictness: enforce pre-net schema.
		-- if schema ~= 'devicecode.pre_net/1.0' then ...
	end

	local profiles          = get_tbl(pre_net_data, 'profiles') or {}
	local network           = get_tbl(pre_net_data, 'network') or {}
	local nets_in           = get_tbl(network, 'nets') or {}

	local desired           = {
		schema = opts.state_schema or 'devicecode.state/2.5',
		snapshot = { rev = rev, gen = gen },
	}

	-- NETWORK
	local network_out, derr = compile_links_and_nets(pre_net_data, rev, gen)
	if not network_out then return nil, derr end

	local routes_out, rerr = compile_routes(pre_net_data)
	if not routes_out then return nil, rerr end
	network_out.routes = routes_out

	-- Normalise globals: only keep known keys, omit if absent.
	local g_in = get_tbl(get_tbl(pre_net_data, 'network') or {}, 'globals') or {}
	network_out.globals = {
		ula_prefix      = g_in.ula_prefix,
		packet_steering = g_in.packet_steering,
		tcp_l3mdev      = g_in.tcp_l3mdev,
		udp_l3mdev      = g_in.udp_l3mdev,
		netifd_loglevel = g_in.netifd_loglevel,
	}

	desired.network = network_out

	-- ADDRESSING
	local addressing_out, aerr = compile_addressing(pre_net_data, nets_in, profiles)
	if not addressing_out then return nil, aerr end
	addressing_out.rev = rev
	desired.addressing = addressing_out

	-- FIREWALL
	local fw_out, fwerr = compile_firewall(pre_net_data, nets_in, profiles)
	if not fw_out then return nil, fwerr end
	fw_out.rev = rev
	desired.firewall = fw_out

	-- MULTIWAN (optional)
	local mw_out, mwerr = compile_multiwan(pre_net_data, nets_in, profiles)
	if mw_out == nil and mwerr ~= nil then
		return nil, mwerr
	end
	if mw_out then
		mw_out.rev = rev
		desired.multiwan = mw_out
	end

	return desired, nil
end

return M
