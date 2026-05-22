-- services/hal/backends/network/providers/openwrt/init.lua
-- OpenWrt semantic network provider.
--
-- This module is the HAL boundary where product-level NET intent is translated
-- into OpenWrt UCI packages.  NET must not require this module directly.

local fibers = require 'fibers'
local op = require 'fibers.op'
local exec = require 'fibers.io.exec'
local cjson = require 'cjson.safe'
local uci_manager = require 'services.hal.backends.openwrt.uci_manager'
local observer_mod = require 'services.hal.backends.network.providers.openwrt.observer'
local mwan3_mod = require 'services.hal.backends.network.providers.openwrt.mwan3'
local shaper_mod = require 'services.hal.backends.network.providers.openwrt.tc_u32_shaper'
local speedtest_mod = require 'services.hal.backends.network.providers.openwrt.speedtest'
local names_mod = require 'services.hal.backends.network.providers.openwrt.names'
local hal_types = require 'services.hal.types.core'

local perform = fibers.perform
local unpack = _G.unpack or rawget(table, 'unpack')

local M = {}
local Provider = {}
Provider.__index = Provider

local read_uci_packages
local snapshot_from_packages
local build_observed_snapshot

local function is_plain_table(v)
	return type(v) == 'table' and getmetatable(v) == nil
end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function count_keys(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function validate_intent(intent)
	if not is_plain_table(intent) then return { ok = false, err = 'intent must be a table', backend = 'openwrt' } end
	if intent.schema ~= nil and intent.schema ~= 'devicecode.net.intent/1' then
		return { ok = false, err = 'unsupported intent schema: ' .. tostring(intent.schema), backend = 'openwrt' }
	end
	if not is_plain_table(intent.segments) then return { ok = false, err = 'intent.segments must be a map', backend = 'openwrt' } end
	if not is_plain_table(intent.interfaces) then return { ok = false, err = 'intent.interfaces must be a map', backend = 'openwrt' } end
	return { ok = true, valid = true, backend = 'openwrt' }
end

local function uci_id(v, prefix)
	local s = tostring(v or '')
	s = s:gsub('[^%w_]', '_')
	if s == '' then s = '_' end
	if not s:match('^[A-Za-z0-9_]') then s = '_' .. s end
	return (prefix or '') .. s
end

local function section_id(kind, id)
	if kind == 'device' then return uci_id('dev_' .. tostring(id)) end
	if kind == 'zone' then return uci_id('zone_' .. tostring(id)) end
	if kind == 'fwd' then return uci_id('fwd_' .. tostring(id)) end
	if kind == 'dhcp' then return uci_id(tostring(id)) end
	return uci_id(id)
end

local function bool_uci(v)
	if v == nil then return nil end
	return v and '1' or '0'
end

local function parse_cidr(cidr)
	if type(cidr) ~= 'string' then return nil, nil end
	local addr, prefix = cidr:match('^([^/]+)/(%d+)$')
	if not addr then return nil, nil end
	prefix = tonumber(prefix)
	if not prefix or prefix < 0 or prefix > 32 then return nil, nil end
	return addr, prefix
end

local function prefix_to_netmask(prefix)
	prefix = tonumber(prefix)
	if not prefix or prefix < 0 or prefix > 32 then return nil end
	local rem = prefix
	local octs = {}
	for i = 1, 4 do
		if rem >= 8 then
			octs[i] = 255
			rem = rem - 8
		elseif rem > 0 then
			octs[i] = 256 - (2 ^ (8 - rem))
			rem = 0
		else
			octs[i] = 0
		end
	end
	return string.format('%d.%d.%d.%d', octs[1], octs[2], octs[3], octs[4])
end


local function netmask_to_prefix(mask)
	if type(mask) ~= 'string' then return nil end
	local a, b, c, d = mask:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if not (a and b and c and d) then return nil end
	local bits = { [255] = 8, [254] = 7, [252] = 6, [248] = 5, [240] = 4, [224] = 3, [192] = 2, [128] = 1, [0] = 0 }
	local pfx, partial = 0, false
	for _, oct in ipairs({ a, b, c, d }) do
		local n = bits[oct]
		if n == nil then return nil end
		if partial and n ~= 0 then return nil end
		if n ~= 8 then partial = true end
		pfx = pfx + n
	end
	return pfx
end

local function cidr_from_addr_netmask(addr, netmask)
	if type(addr) ~= 'string' or addr == '' then return nil end
	local pfx = netmask_to_prefix(netmask)
	if not pfx then return nil end
	return addr .. '/' .. tostring(pfx)
end

local function bool_from_uci(v)
	if v == nil then return nil end
	if v == true or v == '1' or v == 1 or v == 'true' or v == 'yes' or v == 'on' or v == 'enabled' then return true end
	if v == false or v == '0' or v == 0 or v == 'false' or v == 'no' or v == 'off' or v == 'disabled' then return false end
	return nil
end

local function list_from_uci(v)
	if v == nil then return {} end
	if type(v) == 'table' then
		local out = {}
		for i = 1, #v do out[i] = v[i] end
		return out
	end
	return { v }
end

local function copy_plain(v)
	if type(v) ~= 'table' then return v end
	local out = {}
	for k, val in pairs(v) do out[k] = copy_plain(val) end
	return out
end

local function ipv4_spec(primary, fallback)
	local p = is_plain_table(primary) and primary or {}
	local f = is_plain_table(fallback) and fallback or {}
	local ip = p.ipv4 or p.v4 or p
	if not is_plain_table(ip) then ip = {} end
	local fip = f.ipv4 or f.v4 or f
	if not is_plain_table(fip) then fip = {} end

	local out = {}
	for k, v in pairs(fip) do out[k] = v end
	for k, v in pairs(ip) do out[k] = v end
	if out.mode == nil then out.mode = out.proto end
	return out
end

local function cidr_to_addr_prefix(spec)
	if type(spec.cidr) == 'string' then
		local addr, prefix = parse_cidr(spec.cidr)
		if addr then return addr, prefix end
	end
	local addr = spec.address or spec.addr or spec.ip or spec.ipaddr
	local prefix = spec.prefix or spec.prefix_len
	if prefix == nil and type(spec.netmask) == 'string' then return addr, nil, spec.netmask end
	return addr, prefix
end

local function set_section(changes, config, section, stype)
	changes[#changes + 1] = { op = 'set', config = config, section = section, option = stype }
end

local function set_option(changes, config, section, option, value)
	if value == nil then return end
	changes[#changes + 1] = { op = 'set', config = config, section = section, option = option, value = value }
end

local function ensure_pkg_file(confdir, pkg)
	if type(confdir) ~= 'string' or confdir == '' then return true, nil end
	local ok = os.execute("mkdir -p '" .. confdir:gsub("'", "'\\''") .. "'")
	if ok ~= true and ok ~= 0 then return nil, 'failed to create UCI confdir ' .. confdir end
	local path = confdir .. '/' .. pkg
	local f = io.open(path, 'rb')
	if f then f:close(); return true, nil end
	local nf, err = io.open(path, 'wb')
	if not nf then return nil, tostring(err) end
	nf:write('# devicecode generated test config\n')
	nf:close()
	return true, nil
end

local function segment_zone_name(seg_id, seg)
	local fw = is_plain_table(seg and seg.firewall) and seg.firewall or {}
	if type(fw.zone) == 'string' and fw.zone ~= '' then return fw.zone end
	return seg_id
end

local function collect_interface_maps(intent)
	local segment_to_ifaces = {}
	local iface_to_device = {}
	for _, ifid in ipairs(sorted_keys(intent.interfaces or {})) do
		local iface = intent.interfaces[ifid]
		local segs = {}
		if type(iface.segment) == 'string' then segs[#segs + 1] = iface.segment end
		if type(iface.segments) == 'table' then
			for i = 1, #iface.segments do segs[#segs + 1] = iface.segments[i] end
		end
		for i = 1, #segs do
			local sid = segs[i]
			segment_to_ifaces[sid] = segment_to_ifaces[sid] or {}
			segment_to_ifaces[sid][#segment_to_ifaces[sid] + 1] = ifid
		end
		if iface.kind == 'bridge' then
			iface_to_device[ifid] = 'br-' .. ifid
		else
			local ep = is_plain_table(iface.endpoint) and iface.endpoint or {}
			iface_to_device[ifid] = ep.ifname or ep.device or ep.name or iface.device
		end
	end
	for _, list in pairs(segment_to_ifaces) do table.sort(list) end
	return segment_to_ifaces, iface_to_device
end


local function segment_vlan_id(seg)
	local vlan = seg and seg.vlan
	if type(vlan) == 'number' then return vlan end
	if is_plain_table(vlan) then return vlan.id end
	return nil
end

local function platform_segment_trunk(provider_config)
	provider_config = provider_config or {}
	local platform = is_plain_table(provider_config.platform) and provider_config.platform or {}
	local trunk = platform.segment_trunk or provider_config.segment_trunk
	if not is_plain_table(trunk) then return nil end
	local ifname = trunk.ifname or trunk.device or trunk.name
	if type(ifname) ~= 'string' or ifname == '' then return nil end
	return trunk, ifname
end

local function segment_is_enabled(seg)
	return is_plain_table(seg) and seg.enabled ~= false
end


local function first_value(v)
	if type(v) == 'table' then return v[1] end
	return v
end

local function list_contains(list, value)
	if type(list) ~= 'table' then return false end
	for i = 1, #list do if list[i] == value then return true end end
	return false
end

local function ensure_array(v)
	if v == nil then return {} end
	if type(v) == 'table' then
		local out = {}
		if #v > 0 then
			for i = 1, #v do out[#out + 1] = v[i] end
		else
			for _, k in ipairs(sorted_keys(v)) do out[#out + 1] = v[k] end
		end
		return out
	end
	return { v }
end

local function dirname(path)
	if type(path) ~= 'string' then return nil end
	local d = path:match('^(.+)/[^/]+$')
	return d
end

local function add_unique_value(out, seen, v)
	if type(v) ~= 'string' or v == '' or seen[v] then return end
	seen[v] = true
	out[#out + 1] = v
end

local function dns_records_for_segment(dns, seg_id)
	local out = {}
	local records = is_plain_table(dns.records) and dns.records or {}
	local function add_record(rid, rec)
		if not is_plain_table(rec) then return end
		local name = rec.name or rid
		local addr = rec.address or rec.ip or rec.value
		if type(name) ~= 'string' or name == '' or type(addr) ~= 'string' or addr == '' then return end
		if rec.segment ~= nil and rec.segment ~= seg_id then return end
		if rec.segments ~= nil and not list_contains(rec.segments, seg_id) then return end
		out[#out + 1] = '/' .. name .. '/' .. addr
	end
	if #records > 0 then
		for i = 1, #records do add_record(tostring(i), records[i]) end
	else
		for _, rid in ipairs(sorted_keys(records)) do add_record(rid, records[rid]) end
	end
	table.sort(out)
	return out
end

local function resolve_host_file_sources(dns, seg)
	local cfg = is_plain_table(dns.host_files) and dns.host_files or {}
	local base_dir = cfg.base_dir or cfg.root or cfg.dir or '/data/devicecode/dns/hosts'
	local sources = is_plain_table(cfg.sources) and cfg.sources or {}
	local seg_dns = is_plain_table(seg.dns) and seg.dns or {}
	local ids = seg_dns.host_files or seg_dns.host_sources or {}
	local files, mounts, seen_files, seen_mounts = {}, {}, {}, {}
	if cfg.addnmount ~= false then add_unique_value(mounts, seen_mounts, base_dir) end
	for _, source_id in ipairs(ensure_array(ids)) do
		local path
		local sid = tostring(source_id)
		local spec = is_plain_table(sources[sid]) and sources[sid] or nil
		if spec then
			path = spec.path or (spec.file and (base_dir .. '/' .. tostring(spec.file))) or (base_dir .. '/' .. sid .. '.hosts')
		else
			path = sid:sub(1, 1) == '/' and sid or (base_dir .. '/' .. sid .. '.hosts')
		end
		add_unique_value(files, seen_files, path)
		add_unique_value(mounts, seen_mounts, dirname(path))
	end
	table.sort(files)
	table.sort(mounts)
	return files, mounts
end

local function segment_ipv4_cidr(seg)
	local ipv4 = ipv4_spec(seg and seg.addressing or {}, {})
	if type(ipv4.cidr) == 'string' then return ipv4.cidr end
	local addr, prefix, netmask = cidr_to_addr_prefix(ipv4)
	if type(addr) == 'string' and prefix ~= nil then return addr .. '/' .. tostring(prefix) end
	if type(addr) == 'string' and type(netmask) == 'string' then return cidr_from_addr_netmask(addr, netmask) end
	return nil
end

local function route_entries(routes)
	local out = {}
	if not is_plain_table(routes) then return out end
	if #routes > 0 then
		for i = 1, #routes do if is_plain_table(routes[i]) then out[#out + 1] = { id = tostring(i), rec = routes[i] } end end
	else
		for _, id in ipairs(sorted_keys(routes)) do if is_plain_table(routes[id]) then out[#out + 1] = { id = id, rec = routes[id] } end end
	end
	return out
end


local function merge_tables(a, b)
	local out = {}
	for k, v in pairs(a or {}) do out[k] = copy_plain(v) end
	for k, v in pairs(b or {}) do out[k] = copy_plain(v) end
	return out
end

local function resolve_shaping_profile(shaping, seg)
	local seg_shape = is_plain_table(seg.shaping) and seg.shaping or {}
	local profiles = is_plain_table(shaping.profiles) and shaping.profiles or {}
	local profile_name = seg_shape.profile or seg_shape.profile_id
	local base = {}
	if type(profile_name) == 'string' and is_plain_table(profiles[profile_name]) then base = profiles[profile_name] end
	local overrides = is_plain_table(seg_shape.overrides) and seg_shape.overrides or {}
	return merge_tables(base, overrides), profile_name
end

local function segment_shaping_device(provider_config, seg_id, seg)
	local trunk, base_ifname = platform_segment_trunk(provider_config)
	local vid = segment_vlan_id(seg)
	if trunk and base_ifname and vid then return base_ifname .. '.' .. tostring(vid) end
	return nil
end

local function build_shaping_request(intent, provider_config)
	local shaping = is_plain_table(intent.shaping) and intent.shaping or {}
	if shaping.enabled ~= true then return shaping end
	local links = {}
	for k, v in pairs(shaping.links or {}) do links[k] = copy_plain(v) end
	for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
		local seg = intent.segments[seg_id]
		local seg_shape = is_plain_table(seg.shaping) and seg.shaping or {}
		if seg_shape.enabled ~= false and (seg_shape.profile or seg_shape.profile_id) then
			local spec = resolve_shaping_profile(shaping, seg)
			if is_plain_table(spec) and spec.enabled ~= false then
				local iface = spec.iface or spec.device or segment_shaping_device(provider_config, seg_id, seg)
				local subnet = spec.subnet or spec.cidr or segment_ipv4_cidr(seg)
				if iface and subnet then
					local one = copy_plain(spec)
					one.iface = iface
					one.subnet = subnet
					one.segment = seg_id
					one.profile = seg_shape.profile or seg_shape.profile_id
					links[seg_id] = one
				end
			end
		end
	end
	local out = copy_plain(shaping)
	out.links = links
	return out
end


local function build_segment_interface_proto(seg)
	local ipv4 = ipv4_spec(seg and seg.addressing or {}, {})
	local proto = ipv4.mode or ipv4.proto
	if proto == nil then
		local addr = cidr_to_addr_prefix(ipv4)
		proto = addr and 'static' or 'none'
	end
	if proto == 'manual' then proto = 'none' end
	return proto, ipv4
end

local function add_segment_trunk_interfaces(changes, known, intent, provider_config, segment_to_ifaces)
	local _trunk, base_ifname = platform_segment_trunk(provider_config)
	if not base_ifname then return end

	for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
		local seg = intent.segments[seg_id]
		if segment_is_enabled(seg) and not (segment_to_ifaces[seg_id] and #segment_to_ifaces[seg_id] > 0) then
			local vid = segment_vlan_id(seg)
			if vid then
				local devname = base_ifname .. '.' .. tostring(vid)
				local devsec = section_id('device', 'seg_' .. seg_id)
				local ifsec = section_id('interface', seg_id)
				known[devsec] = true
				known[ifsec] = true

				set_section(changes, 'network', devsec, 'device')
				set_option(changes, 'network', devsec, 'type', '8021q')
				set_option(changes, 'network', devsec, 'ifname', base_ifname)
				set_option(changes, 'network', devsec, 'vid', vid)
				set_option(changes, 'network', devsec, 'name', devname)

				local proto, ipv4 = build_segment_interface_proto(seg)
				set_section(changes, 'network', ifsec, 'interface')
				set_option(changes, 'network', ifsec, 'proto', proto)
				set_option(changes, 'network', ifsec, 'auto', '1')
				set_option(changes, 'network', ifsec, 'disabled', '0')
				set_option(changes, 'network', ifsec, 'device', devname)

				if proto == 'static' then
					local addr, prefix, netmask = cidr_to_addr_prefix(ipv4)
					set_option(changes, 'network', ifsec, 'ipaddr', addr)
					set_option(changes, 'network', ifsec, 'netmask', netmask or prefix_to_netmask(prefix))
					set_option(changes, 'network', ifsec, 'gateway', ipv4.gateway or ipv4.gw)
					set_option(changes, 'network', ifsec, 'dns', ipv4.dns)
				else
					set_option(changes, 'network', ifsec, 'peerdns', bool_uci(ipv4.peerdns))
					if ipv4.metric then set_option(changes, 'network', ifsec, 'metric', ipv4.metric) end
				end

				segment_to_ifaces[seg_id] = segment_to_ifaces[seg_id] or {}
				segment_to_ifaces[seg_id][#segment_to_ifaces[seg_id] + 1] = ifsec
				table.sort(segment_to_ifaces[seg_id])
			end
		end
	end
end

local function add_bridge_vlan_devices(changes, known, intent, iface_id, bridge_name, iface)
	local segs = {}
	if type(iface.segment) == 'string' then segs[#segs + 1] = iface.segment end
	if type(iface.segments) == 'table' then
		for i = 1, #iface.segments do segs[#segs + 1] = iface.segments[i] end
	end
	for i = 1, #segs do
		local seg_id = segs[i]
		local seg = (intent.segments or {})[seg_id]
		local vid = segment_vlan_id(seg)
		if vid then
			local devname = bridge_name .. '.' .. tostring(vid)
			local devsec = section_id('device', iface_id .. '_' .. tostring(vid))
			known[devsec] = true
			set_section(changes, 'network', devsec, 'device')
			set_option(changes, 'network', devsec, 'type', '8021q')
			set_option(changes, 'network', devsec, 'ifname', bridge_name)
			set_option(changes, 'network', devsec, 'vid', vid)
			set_option(changes, 'network', devsec, 'name', devname)
		end
	end
end

local function segment_interface_device(_intent, _iface_id, _iface, base_device)
	-- Keep the logical interface on its bridge by default for compatibility.
	-- The provider still materialises 802.1q devices for VLAN-capable segment
	-- realisation; a later switch/DSA-specific policy can bind interfaces
	-- directly to those devices where appropriate.
	return base_device
end

local function build_network_changes(intent, provider_config)
	local changes = {}
	local known = {}
	local segment_to_ifaces, iface_to_device = collect_interface_maps(intent)

	set_section(changes, 'network', 'globals', 'globals')
	known.globals = true

	add_segment_trunk_interfaces(changes, known, intent, provider_config, segment_to_ifaces)

	for _, ifid in ipairs(sorted_keys(intent.interfaces or {})) do
		local iface = intent.interfaces[ifid]
		local ifsec = section_id('interface', ifid)
		known[ifsec] = true
		if iface.kind == 'bridge' then
			local devsec = section_id('device', ifid)
			known[devsec] = true
			set_section(changes, 'network', devsec, 'device')
			set_option(changes, 'network', devsec, 'name', 'br-' .. ifid)
			set_option(changes, 'network', devsec, 'type', 'bridge')
			set_option(changes, 'network', devsec, 'ports', iface.members or {})
			add_bridge_vlan_devices(changes, known, intent, ifid, 'br-' .. ifid, iface)
		end

		local seg = iface.segment and (intent.segments or {})[iface.segment] or nil
		local ipv4 = ipv4_spec(iface.addressing, seg and seg.addressing or {})
		local proto = ipv4.mode or ipv4.proto
		if proto == nil then
			if iface.role == 'wan' then proto = 'dhcp' else proto = 'static' end
		end
		if proto == 'manual' then proto = 'none' end

		set_section(changes, 'network', ifsec, 'interface')
		set_option(changes, 'network', ifsec, 'proto', proto)
		set_option(changes, 'network', ifsec, 'auto', iface.enabled == false and '0' or '1')
		set_option(changes, 'network', ifsec, 'disabled', iface.enabled == false and '1' or '0')
		set_option(changes, 'network', ifsec, 'device', segment_interface_device(intent, ifid, iface, iface_to_device[ifid]))
		if iface.mtu then set_option(changes, 'network', ifsec, 'mtu', iface.mtu) end

		if proto == 'static' then
			local addr, prefix, netmask = cidr_to_addr_prefix(ipv4)
			set_option(changes, 'network', ifsec, 'ipaddr', addr)
			set_option(changes, 'network', ifsec, 'netmask', netmask or prefix_to_netmask(prefix))
			set_option(changes, 'network', ifsec, 'gateway', ipv4.gateway or ipv4.gw)
			set_option(changes, 'network', ifsec, 'dns', ipv4.dns)
		else
			set_option(changes, 'network', ifsec, 'peerdns', bool_uci(ipv4.peerdns))
			if ipv4.metric then set_option(changes, 'network', ifsec, 'metric', ipv4.metric) end
		end
	end

	local routes = (is_plain_table(intent.routing) and intent.routing.routes) or {}
	for _, item in ipairs(route_entries(routes)) do
		local r = item.rec
		local rsec = section_id('route', 'route_' .. tostring(item.id))
		known[rsec] = true
		set_section(changes, 'network', rsec, 'route')
		set_option(changes, 'network', rsec, 'interface', r.interface or r.net)
		set_option(changes, 'network', rsec, 'target', r.target)
		set_option(changes, 'network', rsec, 'gateway', r.gateway or r.via)
		set_option(changes, 'network', rsec, 'metric', r.metric)
		set_option(changes, 'network', rsec, 'table', r.table)
	end

	return changes, known, segment_to_ifaces
end

local function build_dhcp_changes(intent)
	local changes = {}
	local known = {}
	local dns = is_plain_table(intent.dns) and intent.dns or {}
	local dhcp = is_plain_table(intent.dhcp) and intent.dhcp or {}
	local defaults = is_plain_table(dhcp.defaults) and dhcp.defaults or {}

	for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
		local seg = intent.segments[seg_id]
		local dh = is_plain_table(seg.dhcp) and seg.dhcp or {}
		local seg_dns = is_plain_table(seg.dns) and seg.dns or {}
		local wants_dns = dns.enabled ~= false and seg_dns.enabled ~= false and (seg_dns.local_server == true or seg_dns['local'] == true or dh.enabled == true or #(ensure_array(seg_dns.host_files or seg_dns.host_sources)) > 0)

		if wants_dns then
			local dnssec = section_id('dns', 'dns_' .. seg_id)
			known[dnssec] = true
			set_section(changes, 'dhcp', dnssec, 'dnsmasq')
			set_option(changes, 'dhcp', dnssec, 'domainneeded', dns.domainneeded ~= nil and bool_uci(dns.domainneeded) or '1')
			set_option(changes, 'dhcp', dnssec, 'boguspriv', dns.boguspriv ~= nil and bool_uci(dns.boguspriv) or '1')
			set_option(changes, 'dhcp', dnssec, 'localservice', dns.localservice ~= nil and bool_uci(dns.localservice) or '1')
			set_option(changes, 'dhcp', dnssec, 'authoritative', defaults.authoritative ~= nil and bool_uci(defaults.authoritative) or '1')
			set_option(changes, 'dhcp', dnssec, 'interface', { seg_id })
			if is_plain_table(dns.cache) and dns.cache.size ~= nil then set_option(changes, 'dhcp', dnssec, 'cachesize', dns.cache.size) end
			if type(dns.upstreams) == 'table' and #dns.upstreams > 0 then set_option(changes, 'dhcp', dnssec, 'server', dns.upstreams) end
			local domain = seg_dns.domain or dns.domain
			if type(domain) == 'string' and domain ~= '' then
				set_option(changes, 'dhcp', dnssec, 'domain', domain)
				set_option(changes, 'dhcp', dnssec, 'local', '/' .. domain .. '/')
				set_option(changes, 'dhcp', dnssec, 'expandhosts', '1')
			end
			local addnhosts, addnmounts = resolve_host_file_sources(dns, seg)
			if #addnhosts > 0 then set_option(changes, 'dhcp', dnssec, 'addnhosts', addnhosts) end
			if #addnmounts > 0 then set_option(changes, 'dhcp', dnssec, 'addnmount', addnmounts) end
			local addresses = dns_records_for_segment(dns, seg_id)
			if #addresses > 0 then set_option(changes, 'dhcp', dnssec, 'address', addresses) end
		end

		local sec = section_id('dhcp', seg_id)
		known[sec] = true
		set_section(changes, 'dhcp', sec, 'dhcp')
		set_option(changes, 'dhcp', sec, 'interface', seg_id)
		if dh.enabled == true then
			set_option(changes, 'dhcp', sec, 'start', dh.start or dh.range_start or defaults.start or 100)
			set_option(changes, 'dhcp', sec, 'limit', dh.limit or dh.range_limit or defaults.limit or 150)
			set_option(changes, 'dhcp', sec, 'leasetime', dh.leasetime or dh.lease_time or defaults.leasetime or defaults.lease_time or '12h')
			local opts = dh.options or (is_plain_table(dhcp.options) and dhcp.options[seg_id])
			if type(opts) == 'table' then set_option(changes, 'dhcp', sec, 'dhcp_option', opts) end
		else
			set_option(changes, 'dhcp', sec, 'ignore', '1')
		end
	end

	local reservations = is_plain_table(dhcp.reservations) and dhcp.reservations or {}
	local function add_reservation(rid, rec)
		if not is_plain_table(rec) then return end
		local sec = section_id('dhcp', 'host_' .. tostring(rid))
		known[sec] = true
		set_section(changes, 'dhcp', sec, 'host')
		set_option(changes, 'dhcp', sec, 'name', rec.name or rid)
		set_option(changes, 'dhcp', sec, 'mac', rec.mac)
		set_option(changes, 'dhcp', sec, 'ip', rec.ip or rec.address)
		set_option(changes, 'dhcp', sec, 'leasetime', rec.leasetime or rec.lease_time)
		set_option(changes, 'dhcp', sec, 'hostid', rec.hostid)
		set_option(changes, 'dhcp', sec, 'duid', rec.duid)
	end
	if #reservations > 0 then
		for i = 1, #reservations do add_reservation(tostring(i), reservations[i]) end
	else
		for _, rid in ipairs(sorted_keys(reservations)) do add_reservation(rid, reservations[rid]) end
	end

	return changes, known
end

local function build_firewall_changes(intent, segment_to_ifaces)
	local changes = {}
	local known = {}
	local fw = is_plain_table(intent.firewall) and intent.firewall or {}
	local defaults = is_plain_table(fw.defaults) and fw.defaults or {}
	set_section(changes, 'firewall', 'defaults', 'defaults')
	known.defaults = true
	local wrote = {}
	for _, key in ipairs({ 'input', 'output', 'forward' }) do
		set_option(changes, 'firewall', 'defaults', key, defaults[key] or (key == 'output' and 'ACCEPT' or 'REJECT'))
		wrote[key] = true
	end
	for _, key in ipairs(sorted_keys(defaults)) do
		if not wrote[key] then set_option(changes, 'firewall', 'defaults', key, defaults[key]) end
	end

	local zone_to_networks = {}
	for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
		local seg = intent.segments[seg_id]
		local zname = segment_zone_name(seg_id, seg)
		zone_to_networks[zname] = zone_to_networks[zname] or {}
		local ifaces = segment_to_ifaces[seg_id]
		if ifaces and #ifaces > 0 then
			for i = 1, #ifaces do zone_to_networks[zname][#zone_to_networks[zname] + 1] = ifaces[i] end
		else
			zone_to_networks[zname][#zone_to_networks[zname] + 1] = seg_id
		end
	end

	local zone_specs = is_plain_table(fw.zones) and fw.zones or {}
	for _, zname in ipairs(sorted_keys(zone_specs)) do zone_to_networks[zname] = zone_to_networks[zname] or {} end
	for _, zname in ipairs(sorted_keys(zone_to_networks)) do
		local zsec = section_id('zone', zname)
		local zspec = is_plain_table(zone_specs[zname]) and zone_specs[zname] or {}
		local nets = zone_to_networks[zname]
		table.sort(nets)
		known[zsec] = true
		set_section(changes, 'firewall', zsec, 'zone')
		set_option(changes, 'firewall', zsec, 'name', zname)
		if #nets > 0 then set_option(changes, 'firewall', zsec, 'network', nets) end
		set_option(changes, 'firewall', zsec, 'input', zspec.input or 'ACCEPT')
		set_option(changes, 'firewall', zsec, 'output', zspec.output or 'ACCEPT')
		set_option(changes, 'firewall', zsec, 'forward', zspec.forward or 'REJECT')
		for _, key in ipairs(sorted_keys(zspec)) do
			if key ~= 'input' and key ~= 'output' and key ~= 'forward' and key ~= 'network' then
				set_option(changes, 'firewall', zsec, key, zspec[key])
			end
		end
	end

	local policies = is_plain_table(fw.policies) and fw.policies or {}
	local n = 0
	for _, pid in ipairs(sorted_keys(policies)) do
		local p = policies[pid]
		if is_plain_table(p) then
			local src = p.src or p.from
			local dest = p.dest or p.to
			if type(src) == 'string' and type(dest) == 'string' then
				n = n + 1
				local sec = section_id('fwd', pid .. '_' .. tostring(n))
				known[sec] = true
				set_section(changes, 'firewall', sec, 'forwarding')
				set_option(changes, 'firewall', sec, 'src', src)
				set_option(changes, 'firewall', sec, 'dest', dest)
			end
		end
	end

	local rules = is_plain_table(fw.rules) and fw.rules or {}
	local function add_rule(rid, r)
		if not is_plain_table(r) then return end
		local sec = section_id('rule', 'rule_' .. tostring(rid))
		known[sec] = true
		set_section(changes, 'firewall', sec, 'rule')
		set_option(changes, 'firewall', sec, 'name', r.name or rid)
		for _, key in ipairs({
			'enabled', 'family', 'src', 'dest', 'proto', 'src_ip', 'dest_ip', 'src_port', 'dest_port',
			'icmp_type', 'target', 'limit', 'limit_burst', 'extra', 'utc_time', 'weekdays', 'monthdays',
			'start_time', 'stop_time', 'start_date', 'stop_date'
		}) do
			set_option(changes, 'firewall', sec, key, r[key])
		end
	end
	if #rules > 0 then
		for i = 1, #rules do add_rule(tostring(i), rules[i]) end
	else
		for _, rid in ipairs(sorted_keys(rules)) do add_rule(rid, rules[rid]) end
	end

	return changes, known
end


-- Strict generated-name builders.  These supersede the older section-level
-- reconciler path above: Devicecode owns the OpenWrt UCI packages completely,
-- and all OpenWrt-visible names are allocated through names.lua.


local function seg_l2_mode(seg)
	local l2 = is_plain_table(seg and seg.l2) and seg.l2 or {}
	if type(l2.mode) == 'string' and l2.mode ~= '' then return l2.mode end
	local kind = seg and seg.kind or 'lan'
	if kind == 'wan' or kind == 'uplink' then return 'direct' end
	return 'bridge'
end

local function add_static_or_dhcp_interface(changes, ifsec, devname, proto, ipv4, auto, semantic_id)
	set_section(changes, 'network', ifsec, 'interface')
	set_option(changes, 'network', ifsec, 'proto', proto)
	set_option(changes, 'network', ifsec, 'auto', auto == false and '0' or '1')
	set_option(changes, 'network', ifsec, 'disabled', auto == false and '1' or '0')
	set_option(changes, 'network', ifsec, 'device', devname)
	if proto == 'static' then
		local addr, prefix, netmask = cidr_to_addr_prefix(ipv4)
		set_option(changes, 'network', ifsec, 'ipaddr', addr)
		set_option(changes, 'network', ifsec, 'netmask', netmask or prefix_to_netmask(prefix))
		set_option(changes, 'network', ifsec, 'gateway', ipv4.gateway or ipv4.gw)
		set_option(changes, 'network', ifsec, 'dns', ipv4.dns)
	else
		set_option(changes, 'network', ifsec, 'peerdns', bool_uci(ipv4.peerdns))
		set_option(changes, 'network', ifsec, 'defaultroute', bool_uci(ipv4.defaultroute))
		if ipv4.metric then set_option(changes, 'network', ifsec, 'metric', ipv4.metric) end
	end
end

local function build_network_changes_v2(intent, provider_config, name_ctx)
	local changes = {}
	local known = {}
	local segment_to_ifaces = {}

	set_section(changes, 'network', 'loopback', 'interface')
	known.loopback = true
	set_option(changes, 'network', 'loopback', 'device', 'lo')
	set_option(changes, 'network', 'loopback', 'proto', 'static')
	set_option(changes, 'network', 'loopback', 'ipaddr', '127.0.0.1')
	set_option(changes, 'network', 'loopback', 'netmask', '255.0.0.0')

	set_section(changes, 'network', 'globals', 'globals')
	known.globals = true
	set_option(changes, 'network', 'globals', 'ula_prefix', ((intent.addressing or {}).ipv6 or {}).ula_prefix or 'auto')

	local _trunk, base_ifname = platform_segment_trunk(provider_config)
	local explicit_segment = {}
	for _, ifid in ipairs(sorted_keys(intent.interfaces or {})) do
		local iface = intent.interfaces[ifid]
		if type(iface.segment) == 'string' then explicit_segment[iface.segment] = true end
		if type(iface.segments) == 'table' then
			for i = 1, #iface.segments do explicit_segment[iface.segments[i]] = true end
		end
	end

	if base_ifname then
		for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
			local seg = intent.segments[seg_id]
			if segment_is_enabled(seg) and not explicit_segment[seg_id] then
				local vid = segment_vlan_id(seg)
				if vid then
					local vlan_name = name_ctx:vlan(seg_id)
					local vlan_sec = name_ctx:section('dev_vlan', seg_id)
					known[vlan_sec] = true
					set_section(changes, 'network', vlan_sec, 'device')
					set_option(changes, 'network', vlan_sec, 'type', '8021q')
					set_option(changes, 'network', vlan_sec, 'ifname', base_ifname)
					set_option(changes, 'network', vlan_sec, 'vid', vid)
					set_option(changes, 'network', vlan_sec, 'name', vlan_name)

					local devname = vlan_name
					if seg_l2_mode(seg) == 'bridge' then
						local br_name = name_ctx:bridge(seg_id)
						local br_sec = name_ctx:section('dev_bridge', seg_id)
						known[br_sec] = true
						set_section(changes, 'network', br_sec, 'device')
						set_option(changes, 'network', br_sec, 'name', br_name)
						set_option(changes, 'network', br_sec, 'type', 'bridge')
						set_option(changes, 'network', br_sec, 'ports', { vlan_name })
						set_option(changes, 'network', br_sec, 'bridge_empty', '1')
						devname = br_name
					end

					local ifsec = name_ctx:iface(seg_id)
					known[ifsec] = true
					local proto, ipv4 = build_segment_interface_proto(seg)
					if seg.kind == 'wan' and proto == 'dhcp' and ipv4.defaultroute == nil then ipv4.defaultroute = false end
					add_static_or_dhcp_interface(changes, ifsec, devname, proto, ipv4, true, seg_id)
					segment_to_ifaces[seg_id] = segment_to_ifaces[seg_id] or {}
					segment_to_ifaces[seg_id][#segment_to_ifaces[seg_id] + 1] = ifsec
				end
			end
		end
	end

	for _, ifid in ipairs(sorted_keys(intent.interfaces or {})) do
		local iface = intent.interfaces[ifid]
		local ifsec = name_ctx:iface(ifid)
		known[ifsec] = true
		local devname
		if iface.kind == 'bridge' then
			devname = name_ctx:bridge(ifid)
			local devsec = name_ctx:section('dev_bridge', ifid)
			known[devsec] = true
			set_section(changes, 'network', devsec, 'device')
			set_option(changes, 'network', devsec, 'name', devname)
			set_option(changes, 'network', devsec, 'type', 'bridge')
			set_option(changes, 'network', devsec, 'ports', iface.members or {})
			set_option(changes, 'network', devsec, 'bridge_empty', '1')
		else
			local ep = is_plain_table(iface.endpoint) and iface.endpoint or {}
			devname = ep.ifname or ep.device or ep.name or iface.device
		end
		local seg = iface.segment and (intent.segments or {})[iface.segment] or nil
		local ipv4 = ipv4_spec(iface.addressing, seg and seg.addressing or {})
		local proto = ipv4.mode or ipv4.proto
		if proto == nil then proto = iface.role == 'wan' and 'dhcp' or 'static' end
		if proto == 'manual' then proto = 'none' end
		if iface.role == 'wan' and proto == 'dhcp' and ipv4.defaultroute == nil then ipv4.defaultroute = false end
		add_static_or_dhcp_interface(changes, ifsec, devname, proto, ipv4, iface.enabled ~= false, ifid)
		if iface.mtu then set_option(changes, 'network', ifsec, 'mtu', iface.mtu) end

		local segs = {}
		if type(iface.segment) == 'string' then segs[#segs + 1] = iface.segment end
		if type(iface.segments) == 'table' then for i = 1, #iface.segments do segs[#segs + 1] = iface.segments[i] end end
		for i = 1, #segs do
			segment_to_ifaces[segs[i]] = segment_to_ifaces[segs[i]] or {}
			segment_to_ifaces[segs[i]][#segment_to_ifaces[segs[i]] + 1] = ifsec
		end
	end
	for _, list in pairs(segment_to_ifaces) do table.sort(list) end

	local routes = (is_plain_table(intent.routing) and intent.routing.routes) or {}
	for _, item in ipairs(route_entries(routes)) do
		local r = item.rec
		local rsec = name_ctx:section('route', item.id)
		known[rsec] = true
		set_section(changes, 'network', rsec, 'route')
		set_option(changes, 'network', rsec, 'interface', r.interface and name_ctx:iface(r.interface) or r.net)
		set_option(changes, 'network', rsec, 'target', r.target)
		set_option(changes, 'network', rsec, 'gateway', r.gateway or r.via)
		set_option(changes, 'network', rsec, 'metric', r.metric)
		set_option(changes, 'network', rsec, 'table', r.table)
	end

	return changes, known, segment_to_ifaces
end

local function canonical_list(list)
	local out = ensure_array(list)
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

local function list_key(list)
	local out = {}
	for i = 1, #(list or {}) do out[i] = tostring(list[i]) end
	return table.concat(out, ',')
end

local function dns_effective_for_segment(dns, dhcp, seg_id, seg)
	local dh = is_plain_table(seg.dhcp) and seg.dhcp or {}
	local seg_dns = is_plain_table(seg.dns) and seg.dns or {}
	local host_ids = canonical_list(seg_dns.host_files or seg_dns.host_sources or {})
	local wants_dns = dns.enabled ~= false and seg_dns.enabled ~= false and (dh.enabled == true or seg_dns.local_server == true or seg_dns['local'] == true or #host_ids > 0)
	if not wants_dns then return nil end
	local addnhosts, addnmounts = resolve_host_file_sources(dns, seg)
	local addresses = dns_records_for_segment(dns, seg_id)
	local domain = seg_dns.domain or dns.domain
	local upstreams = canonical_list(dns.upstreams or {})
	local label = #host_ids > 0 and table.concat(host_ids, '_') or 'standard'
	local key = table.concat({
		tostring(domain or ''),
		list_key(upstreams),
		list_key(addnhosts),
		list_key(addnmounts),
		list_key(addresses),
		tostring(dns.domainneeded ~= false),
		tostring(dns.boguspriv ~= false),
		tostring(dns.localservice ~= false),
	}, '|')
	return {
		key = key,
		label = label,
		domain = domain,
		upstreams = upstreams,
		addnhosts = addnhosts,
		addnmounts = addnmounts,
		addresses = addresses,
		cachesize = is_plain_table(dns.cache) and dns.cache.size or nil,
		authoritative = (is_plain_table(dhcp.defaults) and dhcp.defaults.authoritative),
	}
end

local function build_dhcp_changes_v2(intent, name_ctx, segment_to_ifaces)
	local changes = {}
	local known = {}
	local dns = is_plain_table(intent.dns) and intent.dns or {}
	local dhcp = is_plain_table(intent.dhcp) and intent.dhcp or {}
	local defaults = is_plain_table(dhcp.defaults) and dhcp.defaults or {}
	local groups = {}
	local seg_instance = {}

	for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
		local seg = intent.segments[seg_id]
		local eff = dns_effective_for_segment(dns, dhcp, seg_id, seg)
		if eff then
			groups[eff.key] = groups[eff.key] or eff
			groups[eff.key].segments = groups[eff.key].segments or {}
			groups[eff.key].interfaces = groups[eff.key].interfaces or {}
			groups[eff.key].segments[#groups[eff.key].segments + 1] = seg_id
			local ifaces = segment_to_ifaces[seg_id] or { name_ctx:iface(seg_id) }
			for i = 1, #ifaces do groups[eff.key].interfaces[#groups[eff.key].interfaces + 1] = ifaces[i] end
			seg_instance[seg_id] = eff.key
		end
	end

	for _, key in ipairs(sorted_keys(groups)) do
		local g = groups[key]
		table.sort(g.interfaces)
		local dnssec = name_ctx:dns_instance(g.label .. '_' .. key)
		known[dnssec] = true
		set_section(changes, 'dhcp', dnssec, 'dnsmasq')
		set_option(changes, 'dhcp', dnssec, 'domainneeded', dns.domainneeded ~= nil and bool_uci(dns.domainneeded) or '1')
		set_option(changes, 'dhcp', dnssec, 'boguspriv', dns.boguspriv ~= nil and bool_uci(dns.boguspriv) or '1')
		set_option(changes, 'dhcp', dnssec, 'localise_queries', '1')
		set_option(changes, 'dhcp', dnssec, 'rebind_protection', '1')
		set_option(changes, 'dhcp', dnssec, 'rebind_localhost', '1')
		set_option(changes, 'dhcp', dnssec, 'expandhosts', '1')
		set_option(changes, 'dhcp', dnssec, 'nonegcache', '0')
		set_option(changes, 'dhcp', dnssec, 'readethers', '1')
		set_option(changes, 'dhcp', dnssec, 'nonwildcard', '1')
		set_option(changes, 'dhcp', dnssec, 'localservice', dns.localservice ~= nil and bool_uci(dns.localservice) or '1')
		set_option(changes, 'dhcp', dnssec, 'authoritative', g.authoritative ~= nil and bool_uci(g.authoritative) or '1')
		set_option(changes, 'dhcp', dnssec, 'port', '53')
		set_option(changes, 'dhcp', dnssec, 'noresolv', '1')
		set_option(changes, 'dhcp', dnssec, 'interface', g.interfaces)
		set_option(changes, 'dhcp', dnssec, 'leasefile', '/tmp/dhcp.leases.' .. dnssec)
		set_option(changes, 'dhcp', dnssec, 'resolvfile', '/tmp/resolv.conf.d/resolv.conf.auto')
		if g.cachesize ~= nil then set_option(changes, 'dhcp', dnssec, 'cachesize', g.cachesize) end
		if #g.upstreams > 0 then set_option(changes, 'dhcp', dnssec, 'server', g.upstreams) end
		if type(g.domain) == 'string' and g.domain ~= '' then
			set_option(changes, 'dhcp', dnssec, 'domain', g.domain)
			set_option(changes, 'dhcp', dnssec, 'local', '/' .. g.domain .. '/')
		end
		if #g.addnhosts > 0 then set_option(changes, 'dhcp', dnssec, 'addnhosts', g.addnhosts) end
		if #g.addnmounts > 0 then set_option(changes, 'dhcp', dnssec, 'addnmount', g.addnmounts) end
		if #g.addresses > 0 then set_option(changes, 'dhcp', dnssec, 'address', g.addresses) end
		g.instance = dnssec
	end

	for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
		local seg = intent.segments[seg_id]
		local dh = is_plain_table(seg.dhcp) and seg.dhcp or {}
		local sec = name_ctx:section('dhcp', seg_id)
		known[sec] = true
		set_section(changes, 'dhcp', sec, 'dhcp')
		set_option(changes, 'dhcp', sec, 'interface', (segment_to_ifaces[seg_id] and segment_to_ifaces[seg_id][1]) or name_ctx:iface(seg_id))
		local g = groups[seg_instance[seg_id]]
		if g and g.instance then set_option(changes, 'dhcp', sec, 'instance', g.instance) end
		if dh.enabled == true then
			set_option(changes, 'dhcp', sec, 'start', dh.start or dh.range_start or defaults.start or 100)
			set_option(changes, 'dhcp', sec, 'limit', dh.limit or dh.range_limit or defaults.limit or 150)
			set_option(changes, 'dhcp', sec, 'leasetime', dh.leasetime or dh.lease_time or defaults.leasetime or defaults.lease_time or '12h')
			local opts = dh.options or (is_plain_table(dhcp.options) and dhcp.options[seg_id])
			if type(opts) == 'table' then set_option(changes, 'dhcp', sec, 'dhcp_option', opts) end
		else
			set_option(changes, 'dhcp', sec, 'ignore', '1')
		end
	end

	local reservations = is_plain_table(dhcp.reservations) and dhcp.reservations or {}
	local function add_reservation(rid, rec)
		if not is_plain_table(rec) then return end
		local sec = name_ctx:section('host', rid)
		known[sec] = true
		set_section(changes, 'dhcp', sec, 'host')
		set_option(changes, 'dhcp', sec, 'name', rec.name or rid)
		set_option(changes, 'dhcp', sec, 'mac', rec.mac)
		set_option(changes, 'dhcp', sec, 'ip', rec.ip or rec.address)
		set_option(changes, 'dhcp', sec, 'leasetime', rec.leasetime or rec.lease_time)
		set_option(changes, 'dhcp', sec, 'hostid', rec.hostid)
		set_option(changes, 'dhcp', sec, 'duid', rec.duid)
	end
	if #reservations > 0 then for i = 1, #reservations do add_reservation(tostring(i), reservations[i]) end else for _, rid in ipairs(sorted_keys(reservations)) do add_reservation(rid, reservations[rid]) end end

	return changes, known
end

local function build_firewall_changes_v2(intent, segment_to_ifaces, name_ctx)
	local changes = {}
	local known = {}
	local fw = is_plain_table(intent.firewall) and intent.firewall or {}
	local defaults = is_plain_table(fw.defaults) and fw.defaults or {}
	set_section(changes, 'firewall', 'defaults', 'defaults')
	known.defaults = true
	local wrote = {}
	for _, key in ipairs({ 'input', 'output', 'forward' }) do
		set_option(changes, 'firewall', 'defaults', key, defaults[key] or (key == 'output' and 'ACCEPT' or 'REJECT'))
		wrote[key] = true
	end
	for _, key in ipairs(sorted_keys(defaults)) do if not wrote[key] then set_option(changes, 'firewall', 'defaults', key, defaults[key]) end end

	local zone_to_networks = {}
	for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
		local seg = intent.segments[seg_id]
		local zname = segment_zone_name(seg_id, seg)
		zone_to_networks[zname] = zone_to_networks[zname] or {}
		local ifaces = segment_to_ifaces[seg_id]
		if ifaces and #ifaces > 0 then for i = 1, #ifaces do zone_to_networks[zname][#zone_to_networks[zname] + 1] = ifaces[i] end end
	end
	local zone_specs = is_plain_table(fw.zones) and fw.zones or {}
	for _, zname in ipairs(sorted_keys(zone_specs)) do zone_to_networks[zname] = zone_to_networks[zname] or {} end
	for _, zname in ipairs(sorted_keys(zone_to_networks)) do
		local zsec = name_ctx:section('zone', zname)
		local zspec = is_plain_table(zone_specs[zname]) and zone_specs[zname] or {}
		local nets = zone_to_networks[zname]
		table.sort(nets)
		local oz = name_ctx:zone(zname)
		known[zsec] = true
		set_section(changes, 'firewall', zsec, 'zone')
		set_option(changes, 'firewall', zsec, 'name', oz)
		if #nets > 0 then set_option(changes, 'firewall', zsec, 'network', nets) end
		set_option(changes, 'firewall', zsec, 'input', zspec.input or 'ACCEPT')
		set_option(changes, 'firewall', zsec, 'output', zspec.output or 'ACCEPT')
		set_option(changes, 'firewall', zsec, 'forward', zspec.forward or 'REJECT')
		for _, key in ipairs(sorted_keys(zspec)) do
			if key ~= 'input' and key ~= 'output' and key ~= 'forward' and key ~= 'network' then set_option(changes, 'firewall', zsec, key, zspec[key]) end
		end
	end
	local policies = is_plain_table(fw.policies) and fw.policies or {}
	local n = 0
	for _, pid in ipairs(sorted_keys(policies)) do
		local p = policies[pid]
		if is_plain_table(p) then
			local src = p.src or p.from
			local dest = p.dest or p.to
			if type(src) == 'string' and type(dest) == 'string' then
				n = n + 1
				local sec = name_ctx:section('fwd', pid .. '_' .. tostring(n))
				known[sec] = true
				set_section(changes, 'firewall', sec, 'forwarding')
				set_option(changes, 'firewall', sec, 'src', name_ctx:zone(src))
				set_option(changes, 'firewall', sec, 'dest', name_ctx:zone(dest))
			end
		end
	end
	local rules = is_plain_table(fw.rules) and fw.rules or {}
	local function add_rule(rid, r)
		if not is_plain_table(r) then return end
		local sec = name_ctx:section('rule', rid)
		known[sec] = true
		set_section(changes, 'firewall', sec, 'rule')
		set_option(changes, 'firewall', sec, 'name', r.name or rid)
		for _, key in ipairs({ 'enabled', 'family', 'proto', 'src_ip', 'dest_ip', 'src_port', 'dest_port', 'icmp_type', 'target', 'limit', 'limit_burst', 'extra', 'utc_time', 'weekdays', 'monthdays', 'start_time', 'stop_time', 'start_date', 'stop_date' }) do
			set_option(changes, 'firewall', sec, key, r[key])
		end
		if r.src then set_option(changes, 'firewall', sec, 'src', name_ctx:zone(r.src)) end
		if r.dest then set_option(changes, 'firewall', sec, 'dest', name_ctx:zone(r.dest)) end
	end
	if #rules > 0 then for i = 1, #rules do add_rule(tostring(i), rules[i]) end else for _, rid in ipairs(sorted_keys(rules)) do add_rule(rid, rules[rid]) end end
	return changes, known
end

local function reconcile_package_changes(pkg, changes, known, current_pkg)
	local out = {}
	for secname, rec in pairs(current_pkg or {}) do
		if type(secname) == 'string' and secname:sub(1, 1) ~= '.' and type(rec) == 'table' then
			-- Devicecode is the sole UCI writer on managed appliances, so OpenWrt
			-- provider apply is fully reconciliatory: sections absent from the desired
			-- set are removed rather than left as stale configuration.
			if not (known and known[secname]) then
				out[#out + 1] = { op = 'delete', config = pkg, section = secname }
			end
		end
	end
	for i = 1, #(changes or {}) do out[#out + 1] = changes[i] end
	return out
end

local function transaction_record(pkg, changes, _known, _current_pkg, restart_cmds)
	return {
		config = pkg,
		replace_package = true,
		changes = changes or {},
		restart_cmds = restart_cmds or {},
	}
end

local function apply_package(mgr, pkg, changes, known, restart_cmds)
	return mgr:submit_op(transaction_record(pkg, changes, known, nil, restart_cmds))
end

function M.new(config, opts)
	config = config or {}
	opts = opts or {}
	local cfg = {}
	for k, v in pairs(config) do cfg[k] = v end
	local self = setmetatable({
		config = cfg,
		terminated = nil,
		_scope = nil,
		_uci_manager = config.uci_manager,
		_external_uci_manager = config.uci_manager ~= nil,
		_observer = nil,
		cap_emit_ch = opts.cap_emit_ch or config.cap_emit_ch,
		logger = opts.logger or config.logger,
		_runs = {},
		apply_mwan_live_weights = config.apply_mwan_live_weights,
		mwan_run_cmd = config.mwan_run_cmd,
		mwan_run_cmd_capture = config.mwan_run_cmd_capture,
		mwan_run_restore = config.mwan_run_restore,
		shaper_run_cmd = config.shaper_run_cmd or config.run_cmd,
		speedtest_run_cmd = config.speedtest_run_cmd,
	}, Provider)
	return self, nil
end

function Provider:_manager()
	if self._uci_manager then
		if self._uci_manager._closed then
			if self._external_uci_manager then return nil, 'bound UCI manager is closed' end
			self._uci_manager = nil
			self._scope = nil
		else
			return self._uci_manager, nil
		end
	end
	local mgr, err = uci_manager.new({
		confdir = self.config.confdir or self.config.uci_confdir or '/etc/config',
		savedir = self.config.savedir or self.config.uci_savedir,
		allow_fake = self.config.allow_fake_uci == true,
		debounce_s = self.config.debounce_s or 0.02,
		run_cmd = self.config.run_cmd,
	})
	if not mgr then return nil, err end
	self._uci_manager = mgr
	return mgr, nil
end

function Provider:_ensure_started()
	local mgr, err = self:_manager()
	if not mgr then return nil, err end
	local scope = fibers.current_scope()
	if not scope then return nil, 'current scope required' end
	if self._scope == nil then
		self._scope = scope
		local ok, serr = mgr:start(scope)
		if ok ~= true then return nil, serr end
	end
	local confdir = self.config.confdir or self.config.uci_confdir or '/etc/config'
	if mgr._fake ~= true then
		for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
			local ok, eerr = ensure_pkg_file(confdir, pkg)
			if ok ~= true then return nil, eerr end
		end
	end
	return mgr, nil
end


function Provider:_emit_observed(ev)
	if not self.cap_emit_ch then return true, nil end
	local payload, err = hal_types.new.Emit('network-state', 'main', 'event', 'observed', ev)
	if not payload then return nil, err end
	self.cap_emit_ch:put(payload)
	return true, nil
end

function Provider:_snapshot_for_observer(subject, trigger)
	local observed, packages_or_err = build_observed_snapshot(self, { live = true }, subject, trigger)
	if not observed then
		return {
			ok = false,
			backend = 'openwrt',
			err = tostring(packages_or_err),
			subject = subject,
			trigger = trigger,
		}
	end
	return {
		ok = true,
		backend = 'openwrt',
		observed = observed,
		subject = subject,
		trigger = trigger,
		packages = packages_or_err,
	}
end

function Provider:_ensure_observer()
	if self._observer then return self._observer, nil end
	local scope = fibers.current_scope()
	if not scope then return nil, 'current scope required' end
	local obs, err = observer_mod.new({
		logger = self.logger,
		socket_path = self.config.observer_socket_path or self.config.hotplug_socket_path or '/var/run/devicecode-net-observe.sock',
		debounce_s = self.config.observer_debounce_s or self.config.debounce_observation_s or 0.15,
		enable_socket = self.config.enable_hotplug_socket ~= false,
		enable_ubus = self.config.enable_ubus_listener == true,
		initial_snapshot = self.config.initial_observation_snapshot ~= false,
		snapshot = function(subject, trigger) return self:_snapshot_for_observer(subject, trigger) end,
		emit = function(ev) return self:_emit_observed(ev) end,
	})
	if not obs then return nil, err end
	local ok, serr = obs:start(scope)
	if ok ~= true then return nil, serr end
	self._observer = obs
	return obs, nil
end

function Provider:validate_op(req)
	local intent = req and (req.intent or req.desired or req)
	return op.always(validate_intent(intent))
end

function Provider:plan_op(req)
	local intent = req and (req.intent or req.desired or req)
	local valid = validate_intent(intent)
	if not valid or valid.ok ~= true then return op.always(valid) end
	local name_ctx = names_mod.allocate(intent, self.config)
	local n_changes, n_known, segment_to_ifaces = build_network_changes_v2(intent, self.config, name_ctx)
	local d_changes, d_known = build_dhcp_changes_v2(intent, name_ctx, segment_to_ifaces)
	local f_changes, f_known = build_firewall_changes_v2(intent, segment_to_ifaces, name_ctx)
	local m_changes, m_known, m_plan = mwan3_mod.build_changes(intent, name_ctx)
	local shaping = build_shaping_request(intent, self.config)
	local domains = {
		vlan = { status = 'implemented' },
		shaping = { status = shaping.enabled and 'implemented' or 'not_configured' },
		multiwan = { status = (m_plan and m_plan.enabled) and 'implemented' or 'not_configured' },
		vpn = { status = next((intent.vpn and intent.vpn.tunnels) or {}) and 'unsupported' or 'not_configured' },
	}
	return op.always({
		ok = true,
		backend = 'openwrt',
		plan = {
			domains = domains,
			packages = {
				network = { changes = #n_changes, sections = count_keys(n_known) },
				dhcp = { changes = #d_changes, sections = count_keys(d_known) },
				firewall = { changes = #f_changes, sections = count_keys(f_known) },
				mwan3 = { changes = #m_changes, sections = count_keys(m_known) },
			},
			openwrt_names = name_ctx:snapshot(),
		},
	})
end

function Provider:apply_op(req)
	return fibers.run_scope_op(function()
		if self.terminated then return { ok = false, err = 'provider terminated', backend = 'openwrt' } end
		local intent = req and (req.intent or req.desired or req)
		local valid = validate_intent(intent)
		if not valid or valid.ok ~= true then return valid end
		local mgr, merr = self:_ensure_started()
		if not mgr then return { ok = false, err = merr or 'uci manager unavailable', backend = 'openwrt' } end

		local name_ctx = names_mod.allocate(intent, self.config)
		local n_changes, n_known, segment_to_ifaces = build_network_changes_v2(intent, self.config, name_ctx)
		local d_changes, d_known = build_dhcp_changes_v2(intent, name_ctx, segment_to_ifaces)
		local f_changes, f_known = build_firewall_changes_v2(intent, segment_to_ifaces, name_ctx)
		local m_changes, m_known, m_plan = mwan3_mod.build_changes(intent, name_ctx)

		local records = {
			transaction_record('network', n_changes, n_known, nil, {
				{ kind = 'reload', target = 'network' },
			}),
			transaction_record('dhcp', d_changes, d_known, nil, {
				{ kind = 'restart', target = 'dnsmasq' },
			}),
			transaction_record('firewall', f_changes, f_known, nil, {
				{ kind = 'restart', target = 'firewall' },
			}),
			-- Always include mwan3 so stale generated multi-WAN state is removed when
			-- WAN/multi-WAN is disabled or a member disappears.  Structural apply still
			-- does not restart mwan3; live rules are handled separately.
			transaction_record('mwan3', m_changes, m_known, nil, {}),
		}
		local packages = { 'network', 'dhcp', 'firewall', 'mwan3' }
		local tx_result, admitted = fibers.perform(mgr:transaction_op({
			records = records,
			packages = packages,
			rollback = true,
		}))
		if not tx_result or tx_result.ok ~= true then
			return {
				ok = false,
				backend = 'openwrt',
				admitted = admitted,
				status = tx_result and tx_result.status or 'failed',
				err = tx_result and tx_result.err or 'UCI transaction failed',
				rollback = tx_result and tx_result.rollback or nil,
				failed_step = tx_result and tx_result.failed_step or nil,
				failed_config = tx_result and tx_result.failed_config or nil,
				changed = tx_result and tx_result.status == 'failed_rollback_failed' or false,
			}
		end

		self._last_name_ctx = name_ctx
		self._last_openwrt_names = name_ctx:snapshot()

		local shaping_result = nil
		local shaping_request = build_shaping_request(intent, self.config)
		if shaping_request and shaping_request.enabled == true then
			shaping_result = shaper_mod.apply(shaping_request, { run_cmd = self.shaper_run_cmd })
			if not shaping_result or shaping_result.ok ~= true then
				return { ok = false, err = 'traffic shaping apply failed: ' .. tostring(shaping_result and shaping_result.err or 'unknown'), backend = 'openwrt', partial = true }
			end
		end

		return {
			ok = true,
			applied = true,
			changed = true,
			backend = 'openwrt',
			intent_rev = intent.rev,
			packages = packages,
			transaction = tx_result,
			multiwan = m_plan,
			openwrt_names = name_ctx:snapshot(),
			shaping = shaping_result,
		}
	end):wrap(function(status, _report, result)
		if status ~= 'ok' then return { ok = false, err = tostring(result or status), backend = 'openwrt' } end
		return result
	end)
end


local function append_error(list, err)
	if err == nil then return end
	list[#list + 1] = tostring(err)
end

local function command_capture(argv)
	local cmd = exec.command(unpack(argv))
	local out, st, code, sig, err = perform(cmd:combined_output_op())
	local ok = (st == 'exited' and code == 0)
	if ok then return true, out or '', nil end
	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then
		detail = tostring(detail) .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then
		detail = tostring(detail) .. ' (signal ' .. tostring(sig) .. ')'
	end
	return nil, out or '', detail
end

local function ubus_call(config, object, method, payload)
	payload = payload or {}
	local encoded = cjson.encode(payload)
	if type(encoded) ~= 'string' then return nil, 'ubus payload encode failed' end

	local timeout_s = tonumber(config and config.ubus_timeout_s) or 2
	if timeout_s < 1 then timeout_s = 1 end
	local argv = { 'ubus', '-t', tostring(timeout_s), 'call', tostring(object), tostring(method), encoded }

	local ok, out, err = command_capture(argv)
	if not ok then return nil, err end
	local decoded, derr = cjson.decode(out or '')
	if type(decoded) ~= 'table' then return nil, derr or 'ubus JSON decode failed' end
	return decoded, nil
end

local function add_unique(list, value, seen)
	if type(value) ~= 'string' or value == '' then return end
	seen = seen or {}
	if seen[value] then return end
	seen[value] = true
	list[#list + 1] = value
end

local function infer_interface_ids(observed, req, subject, trigger)
	local out, seen = {}, {}
	if type(req) == 'table' and type(req.interfaces) == 'table' then
		for i = 1, #req.interfaces do add_unique(out, req.interfaces[i], seen) end
	end
	local subj_if = type(subject) == 'string' and subject:match('^interface:(.+)$') or nil
	add_unique(out, subj_if, seen)
	local env = type(trigger) == 'table' and (trigger.env or trigger.payload or trigger) or nil
	if type(env) == 'table' then add_unique(out, env.INTERFACE or env.interface, seen) end
	for ifid in pairs((observed and observed.interfaces) or {}) do add_unique(out, ifid, seen) end
	return out
end

local function normalise_interface_status(ifid, st)
	st = is_plain_table(st) and st or {}
	local out = {
		id = ifid,
		up = st.up,
		pending = st.pending,
		available = st.available,
		autostart = st.autostart,
		uptime = st.uptime,
		proto = st.proto,
		device = st.device,
		l3_device = st.l3_device,
		ipv4 = {},
		ipv6 = {},
		routes = {},
		data = copy_plain(st.data or {}),
		raw = copy_plain(st),
	}
	for i = 1, #(st.address or {}) do
		local a = st.address[i]
		if is_plain_table(a) then
			out.ipv4[#out.ipv4 + 1] = { address = a.address, mask = a.mask, ptpaddress = a.ptpaddress }
		end
	end
	for i = 1, #(st['ipv6-address'] or st.ipv6_address or {}) do
		local a = (st['ipv6-address'] or st.ipv6_address)[i]
		if is_plain_table(a) then
			out.ipv6[#out.ipv6 + 1] = { address = a.address, mask = a.mask, preferred = a.preferred, valid = a.valid }
		end
	end
	for i = 1, #(st.route or {}) do
		local r = st.route[i]
		if is_plain_table(r) then
			out.routes[#out.routes + 1] = {
				interface = ifid,
				target = r.target,
				mask = r.mask,
				nexthop = r.nexthop,
				source = r.source,
				metric = r.metric,
				table = r.table,
				proto = r.proto,
			}
		end
	end
	return out
end

local function normalise_device_status(name, st)
	st = is_plain_table(st) and st or {}
	return {
		name = name,
		type = st.type,
		up = st.up,
		link = st.link,
		mtu = st.mtu,
		macaddr = st.macaddr,
		txqueuelen = st.txqueuelen,
		statistics = copy_plain(st.statistics or {}),
		raw = copy_plain(st),
	}
end

local function normalise_mwan3_status(st, name_ctx)
	local out = {
		available = type(st) == 'table',
		interfaces = {},
		interfaces_by_semantic = {},
		policies = {},
		connected = {},
		raw = copy_plain(st or {}),
	}
	if not is_plain_table(st) then return out end
	for ifid, rec in pairs(st.interfaces or {}) do
		if is_plain_table(rec) then
			local probes = {}
			for i = 1, #(rec.track_ip or {}) do
				local p = rec.track_ip[i]
				if is_plain_table(p) then
					probes[#probes + 1] = {
						ip = p.ip,
						status = p.status,
						latency_ms = tonumber(p.latency),
						packetloss_pct = tonumber(p.packetloss),
					}
				end
			end
			local state = rec.status
			if rec.enabled == false then state = 'disabled' end
			local online = state == 'online' or rec.up == true or rec.online == true
			local item = {
				interface = ifid,
				semantic_interface = (name_ctx and type(name_ctx.semantic_for) == 'function' and name_ctx:semantic_for('mwan_iface', ifid)) or ifid,
				state = state,
				mwan3_status = rec.status,
				enabled = rec.enabled,
				running = rec.running,
				tracking = rec.tracking,
				up = rec.up,
				usable = online,
				age = tonumber(rec.age),
				uptime = tonumber(rec.uptime),
				online = online,
				online_count = tonumber(rec.online),
				offline = tonumber(rec.offline),
				score = tonumber(rec.score),
				lost = tonumber(rec.lost),
				turn = tonumber(rec.turn),
				probes = probes,
				raw = copy_plain(rec),
			}
			out.interfaces[ifid] = item
			if item.semantic_interface then out.interfaces_by_semantic[item.semantic_interface] = item end
		end
	end
	out.policies = copy_plain(st.policies or {})
	out.connected = copy_plain(st.connected or {})
	return out
end

local function augment_with_live_snapshot(config, observed, req, subject, trigger)
	observed.live = observed.live or { interfaces = {}, devices = {}, routes = {}, errors = {} }
	local live = observed.live
	local ifaces = infer_interface_ids(observed, req, subject, trigger)
	local devices, device_seen = {}, {}
	for i = 1, #ifaces do
		local ifid = ifaces[i]
		local st, err = ubus_call(config, 'network.interface.' .. tostring(ifid), 'status', {})
		if st then
			local norm = normalise_interface_status(ifid, st)
			live.interfaces[ifid] = norm
			if observed.interfaces[ifid] then observed.interfaces[ifid].live = norm end
			add_unique(devices, norm.device, device_seen)
			add_unique(devices, norm.l3_device, device_seen)
			for j = 1, #norm.routes do live.routes[#live.routes + 1] = norm.routes[j] end
		else
			append_error(live.errors, 'network.interface.' .. tostring(ifid) .. ' status: ' .. tostring(err))
		end
	end
	for _, iface in pairs(observed.interfaces or {}) do
		if iface.endpoint then add_unique(devices, iface.endpoint.ifname or iface.endpoint.device or iface.endpoint.name, device_seen) end
		add_unique(devices, iface.device, device_seen)
	end
	for i = 1, #devices do
		local dev = devices[i]
		local st, err = ubus_call(config, 'network.device', 'status', { name = dev })
		if st then
			live.devices[dev] = normalise_device_status(dev, st)
		else
			append_error(live.errors, 'network.device status ' .. tostring(dev) .. ': ' .. tostring(err))
		end
	end
	local mwan, merr = ubus_call(config, 'mwan3', 'status', {})
	if mwan then
		observed.multiwan = normalise_mwan3_status(mwan, config.name_ctx)
	else
		observed.multiwan = observed.multiwan or { available = false, interfaces = {}, policies = {}, connected = {} }
		observed.multiwan.available = false
		observed.multiwan.err = tostring(merr)
		append_error(live.errors, 'mwan3 status: ' .. tostring(merr))
	end
	return observed
end

function build_observed_snapshot(self, req, subject, trigger)
	req = req or {}
	local packages, err = read_uci_packages(self.config)
	if not packages then return nil, err end
	local observed = snapshot_from_packages(packages)
	if req.live == true and self.config.enable_live_snapshot ~= false then
		local old_ctx = self.config.name_ctx
		self.config.name_ctx = self._last_name_ctx
		augment_with_live_snapshot(self.config, observed, req, subject, trigger)
		self.config.name_ctx = old_ctx
	end
	return observed, packages
end

function read_uci_packages(config)
	local ok, uci_or_err = pcall(require, 'uci')
	if not ok or not uci_or_err or type(uci_or_err.cursor) ~= 'function' then
		return nil, 'uci module unavailable'
	end
	local c = uci_or_err.cursor(config.confdir or config.uci_confdir or '/etc/config', config.savedir or config.uci_savedir)
	local out = {}
	for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
		if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end
		out[pkg] = type(c.get_all) == 'function' and c:get_all(pkg) or {}
	end
	return out, nil
end

function snapshot_from_packages(packages)
	local network = packages.network or {}
	local dhcp = packages.dhcp or {}
	local firewall = packages.firewall or {}
	local mwan3 = packages.mwan3 or {}

	local observed = {
		schema = 'devicecode.net.observed/1',
		segments = {},
		interfaces = {},
		dns = { enabled = true, upstreams = {}, records = {}, host_files = {} },
		dhcp = { pools = {} },
		firewall = { defaults = {}, zones = {}, policies = {}, rules = {} },
		routing = { routes = {} },
		multiwan = { config = { interfaces = {}, members = {}, policies = {}, rules = {} } },
		shaping = { applied = nil },
	}

	local bridge_by_name = {}
	for _, secname in ipairs(sorted_keys(network)) do
		local sec = network[secname]
		if is_plain_table(sec) and sec['.type'] == 'device' and sec.type == 'bridge' and type(sec.name) == 'string' then
			bridge_by_name[sec.name] = {
				section = secname,
				name = sec.name,
				members = list_from_uci(sec.ports),
			}
		end
	end

	for _, secname in ipairs(sorted_keys(network)) do
		local sec = network[secname]
		if is_plain_table(sec) and sec['.type'] == 'interface' then
			local ifid = secname
			local iface = {
				id = ifid,
				segment = ifid,
				role = sec.proto == 'dhcp' and 'wan' or 'lan',
				enabled = sec.disabled ~= '1' and sec.auto ~= '0',
				kind = 'ethernet',
				addressing = { ipv4 = { mode = sec.proto } },
			}
			if type(sec.device) == 'string' and bridge_by_name[sec.device] then
				iface.kind = 'bridge'
				iface.members = bridge_by_name[sec.device].members
			else
				iface.endpoint = { ifname = sec.device }
			end
			if sec.proto == 'static' then
				iface.addressing.ipv4.cidr = cidr_from_addr_netmask(sec.ipaddr, sec.netmask)
				iface.addressing.ipv4.address = sec.ipaddr
				iface.addressing.ipv4.netmask = sec.netmask
				iface.addressing.ipv4.gateway = sec.gateway
			elseif sec.proto == 'dhcp' then
				iface.addressing.ipv4.peerdns = bool_from_uci(sec.peerdns)
				iface.addressing.ipv4.metric = tonumber(sec.metric)
			end
			observed.interfaces[ifid] = iface
			observed.segments[ifid] = observed.segments[ifid] or { id = ifid, interfaces = {} }
			observed.segments[ifid].interfaces[#observed.segments[ifid].interfaces + 1] = ifid
		end
	end

	for _, secname in ipairs(sorted_keys(network)) do
		local sec = network[secname]
		if is_plain_table(sec) and sec['.type'] == 'route' then
			observed.routing.routes[#observed.routing.routes + 1] = {
				id = secname,
				interface = sec.interface,
				target = sec.target,
				gateway = sec.gateway,
			}
		end
	end

	for _, secname in ipairs(sorted_keys(dhcp)) do
		local sec = dhcp[secname]
		if is_plain_table(sec) and sec['.type'] == 'dnsmasq' then
			local interfaces = list_from_uci(sec.interface)
			local upstreams = list_from_uci(sec.server)
			for i = 1, #upstreams do observed.dns.upstreams[#observed.dns.upstreams + 1] = upstreams[i] end
			observed.dns.cache_size = tonumber(sec.cachesize) or sec.cachesize
			observed.dns.host_files[secname] = { interfaces = interfaces, addnhosts = list_from_uci(sec.addnhosts), addnmount = list_from_uci(sec.addnmount) }
			for _, addr in ipairs(list_from_uci(sec.address)) do
				local name, ip = tostring(addr):match('^/([^/]+)/([^/]+)$')
				if name and ip then observed.dns.records[name] = { name = name, address = ip, source = secname, interfaces = interfaces } end
			end
		elseif is_plain_table(sec) and sec['.type'] == 'dhcp' then
			local seg_id = sec.interface or secname
			local enabled = sec.ignore ~= '1'
			observed.dhcp.pools[seg_id] = {
				segment = seg_id,
				enabled = enabled,
				start = tonumber(sec.start) or sec.start,
				limit = tonumber(sec.limit) or sec.limit,
				leasetime = sec.leasetime,
			}
			observed.segments[seg_id] = observed.segments[seg_id] or { id = seg_id, interfaces = {} }
			observed.segments[seg_id].dhcp = observed.dhcp.pools[seg_id]
		end
	end

	for _, secname in ipairs(sorted_keys(firewall)) do
		local sec = firewall[secname]
		if is_plain_table(sec) and sec['.type'] == 'defaults' then
			observed.firewall.defaults = copy_plain(sec)
		elseif is_plain_table(sec) and sec['.type'] == 'zone' then
			local zname = sec.name or secname
			local networks = list_from_uci(sec.network)
			observed.firewall.zones[zname] = {
				name = zname,
				networks = networks,
				input = sec.input,
				output = sec.output,
				forward = sec.forward,
				masq = bool_from_uci(sec.masq),
				mtu_fix = bool_from_uci(sec.mtu_fix),
			}
			for i = 1, #networks do
				local seg_id = networks[i]
				observed.segments[seg_id] = observed.segments[seg_id] or { id = seg_id, interfaces = {} }
				observed.segments[seg_id].firewall = observed.segments[seg_id].firewall or {}
				observed.segments[seg_id].firewall.zone = zname
			end
		elseif is_plain_table(sec) and sec['.type'] == 'forwarding' then
			observed.firewall.policies[secname] = {
				id = secname,
				src = sec.src,
				dest = sec.dest,
			}
		elseif is_plain_table(sec) and sec['.type'] == 'rule' then
			observed.firewall.rules[secname] = copy_plain(sec)
		end
	end


	for _, secname in ipairs(sorted_keys(mwan3)) do
		local sec = mwan3[secname]
		if is_plain_table(sec) and sec['.type'] == 'interface' then
			observed.multiwan.config.interfaces[secname] = {
				name = secname,
				enabled = bool_from_uci(sec.enabled),
				family = sec.family,
				track_ip = list_from_uci(sec.track_ip),
			}
		elseif is_plain_table(sec) and sec['.type'] == 'member' then
			observed.multiwan.config.members[secname] = {
				name = secname,
				interface = sec.interface,
				metric = tonumber(sec.metric),
				weight = tonumber(sec.weight),
			}
		elseif is_plain_table(sec) and sec['.type'] == 'policy' then
			observed.multiwan.config.policies[secname] = {
				name = secname,
				use_member = list_from_uci(sec.use_member),
				last_resort = sec.last_resort,
			}
		elseif is_plain_table(sec) and sec['.type'] == 'rule' then
			observed.multiwan.config.rules[secname] = copy_plain(sec)
		end
	end

	for _, seg in pairs(observed.segments) do
		table.sort(seg.interfaces)
	end

	return observed
end


function Provider:watch_op(_req)
	-- Starting a watch installs long-lived observer workers into the caller's
	-- current scope.  Do not create a private operation-scope boundary
	-- here: it would be joined as soon as watch_op returned, cancelling the
	-- socket server and ubus listener.
	return op.guard(function()
		if self.terminated then
			return op.always({ ok = false, err = 'provider terminated', backend = 'openwrt' })
		end
		local _, merr = self:_ensure_started()
		if merr then
			return op.always({ ok = false, err = merr, backend = 'openwrt' })
		end
		local obs, oerr = self:_ensure_observer()
		if not obs then
			return op.always({ ok = false, err = oerr or 'observer unavailable', backend = 'openwrt' })
		end
		return op.always({
			ok = true,
			backend = 'openwrt',
			watching = true,
			socket_path = obs.socket_path,
		})
	end)
end

function Provider:ingest_observation(trigger)
	local obs, err = self:_ensure_observer()
	if not obs then return nil, err end
	return obs:ingest(trigger)
end

function Provider:snapshot_op(req)
	return fibers.run_scope_op(function()
		local observed, packages_or_err = build_observed_snapshot(self, req or {}, nil, { source = 'snapshot', action = 'manual' })
		if not observed then
			return { ok = false, err = packages_or_err, backend = 'openwrt' }
		end
		return {
			ok = true,
			backend = 'openwrt',
			observed = observed,
			packages = copy_plain(packages_or_err),
		}
	end):wrap(function(status, _report, result)
		if status ~= 'ok' then return { ok = false, err = tostring(result or status), backend = 'openwrt' } end
		return result
	end)
end

function Provider:probe_link_op(_req)
	return op.always({ ok = false, err = 'openwrt network provider probe_link not implemented', backend = 'openwrt' })
end

function Provider:read_counters_op(_req)
	return op.always({ ok = false, err = 'openwrt network provider read_counters not implemented', backend = 'openwrt' })
end



local function translate_mwan_policy_for_ctx(name_ctx, policy)
	if not name_ctx or type(name_ctx.mwan_policy) ~= 'function' then return policy end
	local p = policy or 'balanced'
	if type(p) == 'string' and type(name_ctx.semantic_for) == 'function' and name_ctx:semantic_for('mwan_policy', p) then
		return p
	end
	return name_ctx:mwan_policy(p)
end

local function translate_mwan_iface_for_ctx(name_ctx, iface)
	if not name_ctx or type(name_ctx.mwan_iface) ~= 'function' then return iface end
	if type(iface) ~= 'string' or iface == '' then return iface end
	if type(name_ctx.semantic_for) == 'function' and name_ctx:semantic_for('mwan_iface', iface) then
		return iface
	end
	return name_ctx:mwan_iface(iface)
end

local function translate_live_weights_req(req, name_ctx)
	if not name_ctx then return req or {} end
	local out = copy_plain(req or {}) or {}
	out.policy = translate_mwan_policy_for_ctx(name_ctx, out.policy or 'balanced')
	local members = {}
	for i, m in ipairs((req and req.members) or {}) do
		if is_plain_table(m) then
			local mm = copy_plain(m) or {}
			local semantic_iface = m.openwrt_interface or m.interface or m.iface or m.link_id or m.id
			local generated_iface = translate_mwan_iface_for_ctx(name_ctx, semantic_iface)
			if type(generated_iface) == 'string' and generated_iface ~= '' then
				mm.semantic_interface = semantic_iface
				mm.openwrt_interface = generated_iface
				mm.interface = generated_iface
			end
			members[#members + 1] = mm
		else
			members[#members + 1] = m
		end
	end
	out.members = members
	return out
end

local function translate_speedtest_req(req, name_ctx)
	if not name_ctx then return req or {} end
	local out = copy_plain(req or {}) or {}
	local semantic_iface = out.openwrt_interface or out.interface or out.iface
	local generated_iface = translate_mwan_iface_for_ctx(name_ctx, semantic_iface)
	if type(generated_iface) == 'string' and generated_iface ~= '' then
		out.semantic_interface = semantic_iface
		out.openwrt_interface = generated_iface
		out.interface = generated_iface
	end
	return out
end

function Provider:apply_live_weights_op(req)
	return fibers.run_scope_op(function()
		if self.terminated then return { ok = false, err = 'provider terminated', backend = 'openwrt' } end
		local original_req = req or {}
		local live_req = translate_live_weights_req(original_req, self._last_name_ctx)
		local result = mwan3_mod.apply_live_weights(live_req, {
			apply_mwan_live_weights = self.apply_mwan_live_weights,
			run_cmd = self.mwan_run_cmd,
			run_cmd_capture = self.mwan_run_cmd_capture,
			run_restore = self.mwan_run_restore,
		})
		local persist = req and req.persist ~= false
		if persist then
			local mgr, merr = self:_ensure_started()
			if mgr then
				local ok, err, admitted = fibers.perform(mwan3_mod.persist_weights_op(mgr, original_req, self._last_name_ctx))
				result.persisted = ok == true
				result.persist_err = err
				result.persist_admitted = admitted
			else
				result.persisted = false
				result.persist_err = merr
			end
		end
		return result
	end):wrap(function(status, _report, result)
		if status ~= 'ok' then return { ok = false, err = tostring(result or status), backend = 'openwrt' } end
		return result
	end)
end

function Provider:apply_shaping_op(req)
	return fibers.run_scope_op(function()
		if self.terminated then return { ok = false, err = 'provider terminated', backend = 'openwrt' } end
		local result = shaper_mod.apply(req or {}, { run_cmd = self.shaper_run_cmd })
		if not result then return { ok = false, err = 'traffic shaping apply failed', backend = 'openwrt' } end
		return result
	end):wrap(function(status, _report, result)
		if status ~= 'ok' then return { ok = false, err = tostring(result or status), backend = 'openwrt' } end
		return result
	end)
end

function Provider:speedtest_op(req)
	return speedtest_mod.run_op(translate_speedtest_req(req or {}, self._last_name_ctx), { run_cmd = self.speedtest_run_cmd })
end

function Provider:terminate(reason)
	if self._observer and type(self._observer.terminate) == 'function' then
		self._observer:terminate(reason or 'provider terminated')
	end
	self._observer = nil
	self.terminated = reason or true
	if self._uci_manager and type(self._uci_manager.terminate) == 'function' then
		self._uci_manager:terminate(reason or 'terminated')
	end
	return true, nil
end

return M
