-- services/hal/backends/openwrt.lua
--
-- OpenWrt 21+ HAL backend using libuci-lua for structural writes, and
-- fibers.io.{file,exec} for I/O and process execution.
--
-- Key properties
--   * Replace semantics for structural config apply: wipes and recreates UCI packages.
--   * Testable: supports host.uci_confdir / host.uci_savedir to write UCI elsewhere.
--   * Staging: always writes mwan3 config when present, but only restarts it if installed.
--   * Safe UCI section ids: avoids '-' in section names where libuci can be awkward.
--
-- Runtime extension points added here
--   * list_links
--   * probe_links
--   * read_link_counters
--   * apply_link_shaping_live        -- stub for now
--   * apply_multipath_live           -- stub for now
--   * persist_multipath_state        -- implemented: UCI persistence only
--
-- Boundary
--   This backend is still the only OS-touching layer.
--   It does not make health or policy decisions; it only executes requests.

local fibers  = require 'fibers'
local file    = require 'fibers.io.file'
local exec    = require 'fibers.io.exec'

local perform = fibers.perform

local M       = {}

local function is_plain_table(x) return type(x) == 'table' and getmetatable(x) == nil end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function sanitise_component(s)
	s = tostring(s or '')
	s = s:gsub('[^%w%._%-]', '_')
	if s == '' then s = '_' end
	return s
end

local function sid(x)
	return sanitise_component(x):gsub('%-', '_')
end

local function uci_sec_id(prefix, name)
	-- Conservative UCI section id: avoid '-' and other punctuation.
	-- Keep the real external identifier in an option instead.
	local s = sanitise_component(name):gsub('%-', '_'):gsub('%.', '_')
	return prefix .. s
end

local function state_path(state_dir, ns, key)
	return state_dir .. '/' .. sanitise_component(ns) .. '/' .. sanitise_component(key)
end

local function ns_dir(state_dir, ns)
	return state_dir .. '/' .. sanitise_component(ns)
end

local function trim(s)
	if s == nil then return nil end
	return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function split_lines(s)
	local out = {}
	for line in tostring(s or ''):gmatch('[^\n]+') do
		out[#out + 1] = line
	end
	return out
end

local function sorted_array_from_map_keys(t)
	local out = {}
	for k in pairs(t or {}) do out[#out + 1] = k end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

local function cmd_ok(...)
	local cmd = exec.command(...)
	local out, st, code, sig, err = perform(cmd:combined_output_op())

	if st == 'exited' and code == 0 then
		return true, nil
	end

	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then
		detail = (detail or '') .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then
		detail = (detail or '') .. ' (signal ' .. tostring(sig) .. ')'
	end
	return nil, detail
end

local function cmd_capture(...)
	local cmd = exec.command(...)
	local out, st, code, sig, err = perform(cmd:combined_output_op())

	if st == 'exited' and code == 0 then
		return true, out or '', nil
	end

	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then
		detail = (detail or '') .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then
		detail = (detail or '') .. ' (signal ' .. tostring(sig) .. ')'
	end
	return nil, out or '', detail
end

local function mkdir_p(path)
	local ok, err = cmd_ok('mkdir', '-p', path)
	return ok ~= nil, err
end

local function bool_uci(v)
	if v == nil then return nil end
	return v and '1' or '0'
end

local function uci_set(cur, pkg, sec, opt, v)
	if v == nil then
		cur:delete(pkg, sec, opt)
		return
	end
	local tv = type(v)
	if tv == 'boolean' then
		cur:set(pkg, sec, opt, bool_uci(v))
	elseif tv == 'number' then
		cur:set(pkg, sec, opt, tostring(v))
	elseif tv == 'table' then
		cur:set(pkg, sec, opt, v) -- list value
	else
		cur:set(pkg, sec, opt, tostring(v))
	end
end

local function uci_set_list(cur, pkg, sec, opt, list)
	if list == nil then
		cur:delete(pkg, sec, opt)
		return
	end
	if type(list) ~= 'table' then
		cur:set(pkg, sec, opt, { tostring(list) })
		return
	end
	local out = {}
	for i = 1, #list do out[i] = tostring(list[i]) end
	cur:set(pkg, sec, opt, out)
end

local function uci_try_load(cur, pkg)
	-- Some libuci builds behave better if the package is loaded explicitly,
	-- especially when using a non-standard confdir.
	pcall(function()
		if type(cur.load) == 'function' then cur:load(pkg) end
	end)
end

local function ensure_pkg_file(host, pkg)
	-- For isolated test confdirs: ensure a package file exists so uci show/get_all works.
	if not host or not host.uci_confdir then return true end

	local path = host.uci_confdir .. '/' .. pkg
	local f = io.open(path, 'rb')
	if f then
		f:close()
		return true
	end

	local s, err = file.open(path, 'w')
	if not s then
		return nil, ('failed to create %s: %s'):format(path, tostring(err))
	end
	s:write('# devicecode generated (test confdir)\n')
	s:close()
	return true, nil
end

local function wipe_pkg(cur, pkg)
	uci_try_load(cur, pkg)

	local all = cur:get_all(pkg)
	if type(all) == 'table' then
		for secname in pairs(all) do
			if type(secname) == 'string' and secname:sub(1, 1) ~= '.' then
				cur:delete(pkg, secname)
			end
		end
		return
	end

	-- Fallback: best-effort wipe by common types.
	local types = {
		network  = { 'globals', 'device', 'interface', 'route', 'route6', 'rule', 'rule6' },
		dhcp     = { 'dnsmasq', 'dhcp', 'domain', 'host' },
		firewall = { 'defaults', 'zone', 'forwarding', 'rule', 'redirect', 'include' },
		mwan3    = { 'globals', 'interface', 'member', 'policy', 'rule' },
	}
	for _, tp in ipairs(types[pkg] or {}) do
		cur:foreach(pkg, tp, function(s) cur:delete(pkg, s['.name']) end)
	end
end

local function prefix_to_netmask(prefix)
	prefix = tonumber(prefix)
	if not prefix or prefix < 0 then return nil end
	if prefix > 32 then prefix = 32 end
	local rem = prefix
	local octs = {}
	for i = 1, 4 do
		local b
		if rem >= 8 then
			b = 255
			rem = rem - 8
		elseif rem > 0 then
			b = 256 - (2 ^ (8 - rem))
			rem = 0
		else
			b = 0
		end
		octs[i] = b
	end
	return string.format('%d.%d.%d.%d', octs[1], octs[2], octs[3], octs[4])
end

local function resolve_ifname(host, ifname)
	if type(ifname) ~= 'string' then return ifname, nil end
	if ifname:sub(1, 7) == '@modem.' then
		if host and type(host.resolve_ifname) == 'function' then
			local r = host.resolve_ifname(ifname)
			if type(r) == 'string' and r ~= '' then return r, nil end
			return nil, 'unresolved selector ' .. ifname
		end
		return nil, 'no resolver for selector ' .. ifname
	end
	return ifname, nil
end

local function read_first_line(path)
	local s, err = file.open(path, 'r')
	if not s then return nil, err end
	local line, rerr = s:read_line()
	s:close()
	if rerr ~= nil then return nil, rerr end
	if line == nil then return nil, 'empty file' end
	return tostring(line), nil
end

local function read_u64_file(path)
	local line, err = read_first_line(path)
	if not line then return nil, err end
	local n = tonumber((line:gsub('%s+', '')))
	if n == nil then
		return nil, 'not a number: ' .. tostring(line)
	end
	return n, nil
end

local function file_exists(path)
	local f = io.open(path, 'rb')
	if f then
		f:close()
		return true
	end
	return false
end

local function resolve_network_device(cur, host, link_id)
	-- Resolve a logical OpenWrt interface section name such as "wan" to an
	-- underlying device name such as "eth0.2" or "wwan0".
	--
	-- This is intentionally conservative and supports the shapes your structural
	-- compiler currently writes:
	--   network.<ifid>.device = ...
	-- or legacy:
	--   network.<ifid>.ifname = ...
	if type(link_id) ~= 'string' or link_id == '' then
		return nil, 'link_id must be a non-empty string'
	end

	uci_try_load(cur, 'network')

	local dev = cur:get('network', link_id, 'device')
	if type(dev) == 'string' and dev ~= '' then
		return dev, nil
	end

	dev = cur:get('network', link_id, 'ifname')
	if type(dev) == 'string' and dev ~= '' then
		local resolved, err = resolve_ifname(host, dev)
		if resolved then return resolved, nil end
		return nil, err
	end

	return nil, 'no device/ifname configured for network.' .. tostring(link_id)
end

local function read_sysfs_link_facts(dev)
	local base = '/sys/class/net/' .. tostring(dev)
	if not file_exists(base) then
		return nil, 'device not present in sysfs: ' .. tostring(dev)
	end

	local operstate = read_first_line(base .. '/operstate')
	local carrier_s = read_first_line(base .. '/carrier')
	local mtu_s     = read_first_line(base .. '/mtu')

	return {
		operstate = operstate and trim(operstate) or nil,
		carrier   = (carrier_s ~= nil) and (tonumber(trim(carrier_s)) == 1) or nil,
		mtu       = tonumber(trim(mtu_s or '')),
	}, nil
end

local function read_ipv4_addr_for_device(dev)
	local ok, out = cmd_capture('ip', '-4', 'addr', 'show', 'dev', dev)
	if not ok then return nil end

	for _, line in ipairs(split_lines(out)) do
		local addr = line:match('%s+inet%s+([^%s]+)')
		if addr then return addr end
	end
	return nil
end

local function read_default_route_for_device(dev)
	local ok, out = cmd_capture('ip', '-4', 'route', 'show', 'default', 'dev', dev)
	if not ok then return nil end

	for _, line in ipairs(split_lines(out)) do
		local via = line:match('via%s+([^%s]+)')
		if via then return via end
	end
	return nil
end

local function list_link_ids_from_req(req)
	-- Accept either:
	--   req.links = { "wan", "wanb" }
	-- or
	--   req.links = { wan = {...}, wanb = {...} }
	local out = {}

	if type(req) ~= 'table' then return out end

	if type(req.links) == 'table' then
		local n = 0
		for _, v in ipairs(req.links) do
			n = n + 1
			if type(v) == 'string' and v ~= '' then
				out[#out + 1] = v
			end
		end
		if n > 0 then
			return out
		end

		local ks = sorted_array_from_map_keys(req.links)
		for i = 1, #ks do
			if type(ks[i]) == 'string' and ks[i] ~= '' then
				out[#out + 1] = ks[i]
			end
		end
	end

	return out
end

local function ping_rtt_ms_for_device(dev, reflector, timeout_s, count)
	-- First practical implementation for the shared-probe interface:
	-- use the kernel/device binding that BusyBox ping on OpenWrt provides.
	timeout_s = tonumber(timeout_s) or 2
	count     = math.max(1, math.floor(tonumber(count) or 1))

	local ok, out, err = cmd_capture(
		'ping', '-4',
		'-I', tostring(dev),
		'-c', tostring(count),
		'-W', tostring(math.floor(timeout_s)),
		tostring(reflector)
	)
	if not ok then
		return nil, err
	end

	-- BusyBox ping summary typically contains:
	-- round-trip min/avg/max = 19.637/19.637/19.637 ms
	local minv, avgv = out:match('round%-trip min/avg/max = ([%d%.]+)/([%d%.]+)/')
	if avgv then
		return tonumber(avgv), nil
	end
	if minv then
		return tonumber(minv), nil
	end

	return nil, 'could not parse ping RTT'
end

local function persist_mwan3_live_state(cur, req)
	-- Persist the latest live multipath state into UCI only.
	--
	-- This method does NOT restart mwan3 and does NOT rewrite live dataplane.
	-- It merely ensures that if a later network or service restart happens, the
	-- persisted config reflects the most recently chosen NET policy.
	--
	-- Expected request shape:
	--   {
	--     policy = "default",
	--     last_resort = "unreachable",
	--     members = {
	--       { link_id = "wan",  metric = 1, weight = 3 },
	--       { link_id = "wanb", metric = 1, weight = 1 },
	--     }
	--   }
	if type(req) ~= 'table' then
		return nil, 'request must be a table'
	end

	local policy = req.policy or 'default'
	local members = req.members
	if type(policy) ~= 'string' or policy == '' then
		return nil, 'policy must be a non-empty string'
	end
	if type(members) ~= 'table' then
		return nil, 'members must be an array'
	end

	uci_try_load(cur, 'mwan3')

	local use = {}

	for i = 1, #members do
		local m = members[i]
		if not is_plain_table(m) then
			return nil, ('members[%d] must be a table'):format(i)
		end

		local link_id = m.link_id
		local metric  = tonumber(m.metric)
		local weight  = tonumber(m.weight)

		if type(link_id) ~= 'string' or link_id == '' then
			return nil, ('members[%d].link_id must be a non-empty string'):format(i)
		end
		if metric == nil then
			return nil, ('members[%d].metric must be a number'):format(i)
		end
		if weight == nil then
			return nil, ('members[%d].weight must be a number'):format(i)
		end

		metric = math.max(1, math.floor(metric))
		weight = math.max(1, math.floor(weight))

		-- Persist using the same naming convention as the compiler currently uses.
		-- The section id remains stable; only the weight option changes.
		local member_sec = sid(string.format('%s_m%d_w1', link_id, metric))

		cur:set('mwan3', member_sec, 'member')
		uci_set(cur, 'mwan3', member_sec, 'interface', sid(link_id))
		uci_set(cur, 'mwan3', member_sec, 'metric', metric)
		uci_set(cur, 'mwan3', member_sec, 'weight', weight)

		use[#use + 1] = member_sec
	end

	local policy_sec = sid(policy)
	cur:set('mwan3', policy_sec, 'policy')
	uci_set_list(cur, 'mwan3', policy_sec, 'use_member', use)
	uci_set(cur, 'mwan3', policy_sec, 'last_resort', req.last_resort or 'unreachable')

	cur:commit('mwan3')
	return true, nil
end

local function apply_network(cur, host, desired)
	local net = desired.network
	if not is_plain_table(net) then return nil, 'missing desired.network' end

	wipe_pkg(cur, 'network')

	-- globals
	cur:set('network', 'globals', 'globals')
	local g = net.globals or {}
	uci_set(cur, 'network', 'globals', 'ula_prefix', g.ula_prefix)
	uci_set(cur, 'network', 'globals', 'packet_steering', g.packet_steering)
	uci_set(cur, 'network', 'globals', 'tcp_l3mdev', g.tcp_l3mdev)
	uci_set(cur, 'network', 'globals', 'udp_l3mdev', g.udp_l3mdev)
	uci_set(cur, 'network', 'globals', 'netifd_loglevel', g.netifd_loglevel)

	-- config device bridges (OpenWrt 21+)
	for _, lname in ipairs(sorted_keys(net.links or {})) do
		local l = net.links[lname]
		if is_plain_table(l) and l.kind == 'bridge' then
			local sec = uci_sec_id('dev_', lname)

			cur:set('network', sec, 'device')
			uci_set(cur, 'network', sec, 'name', lname) -- kernel device name
			uci_set(cur, 'network', sec, 'type', 'bridge')
			uci_set_list(cur, 'network', sec, 'ports', l.ports or {})
			uci_set(cur, 'network', sec, 'bridge_empty', l.bridge_empty)

			if host and host.log then
				local got = cur:get('network', sec, 'name')
				if got ~= lname then
					host.log('warn', { what = 'bridge_section_not_visible', sec = sec, expected = lname, got = got })
				end
			end
		end
	end

	-- interfaces
	for _, ifid in ipairs(sorted_keys(net.nets or {})) do
		local i = net.nets[ifid]
		if is_plain_table(i) then
			cur:set('network', ifid, 'interface')
			uci_set(cur, 'network', ifid, 'proto', i.proto)

			uci_set(cur, 'network', ifid, 'auto', (i.auto == false) and '0' or '1')
			uci_set(cur, 'network', ifid, 'disabled', i.disabled and '1' or '0')
			uci_set(cur, 'network', ifid, 'force_link', i.force_link and '1' or nil)

			local dev = i.device or {}
			if type(dev.ref) == 'string' and dev.ref ~= '' then
				uci_set(cur, 'network', ifid, 'device', dev.ref)
			elseif type(dev.ifname) == 'string' and dev.ifname ~= '' then
				local resolved, rerr = resolve_ifname(host, dev.ifname)
				if resolved then
					uci_set(cur, 'network', ifid, 'device', resolved)
				else
					uci_set(cur, 'network', ifid, 'disabled', '1')
					uci_set(cur, 'network', ifid, 'device', nil)
					if host and host.log then
						host.log('warn', { what = 'ifname_unresolved', iface = ifid, selector = dev.ifname, err = rerr })
					end
				end
			end

			if i.proto == 'static' and is_plain_table(i.v4) then
				uci_set(cur, 'network', ifid, 'ipaddr', i.v4.addr)
				uci_set(cur, 'network', ifid, 'netmask', prefix_to_netmask(i.v4.prefix))
				uci_set(cur, 'network', ifid, 'gateway', i.v4.gw)
			else
				uci_set(cur, 'network', ifid, 'ipaddr', nil)
				uci_set(cur, 'network', ifid, 'netmask', nil)
				uci_set(cur, 'network', ifid, 'gateway', nil)
			end

			uci_set(cur, 'network', ifid, 'peerdns',
				(i.peerdns ~= nil) and (i.peerdns and '1' or '0') or nil)
			uci_set(cur, 'network', ifid, 'metric', i.metric)
			uci_set(cur, 'network', ifid, 'dns', i.dns)
		end
	end

	-- routes (ipv4 only for now)
	for _, r in ipairs(net.routes or {}) do
		if is_plain_table(r) then
			local sec = cur:add('network', 'route')
			uci_set(cur, 'network', sec, 'interface', r.net)
			uci_set(cur, 'network', sec, 'target', r.target)
			uci_set(cur, 'network', sec, 'gateway', r.via)
		end
	end

	cur:commit('network')
	return true, nil
end

local function apply_dhcp(cur, desired)
	local addr = desired.addressing
	if not is_plain_table(addr) then return nil, 'missing desired.addressing' end

	wipe_pkg(cur, 'dhcp')

	-- single dnsmasq instance (baseline)
	cur:set('dhcp', 'dnsmasq', 'dnsmasq')
	uci_set(cur, 'dhcp', 'dnsmasq', 'noresolv', '1')

	local dns = addr.dns or {}
	local plain = dns.plain or {}
	if not is_plain_table(plain) then plain = {} end

	uci_set(cur, 'dhcp', 'dnsmasq', 'cachesize', plain.cache_size)
	if type(plain.upstream_servers) == 'table' and #plain.upstream_servers > 0 then
		uci_set_list(cur, 'dhcp', 'dnsmasq', 'server', plain.upstream_servers)
	end

	-- pools
	for _, pool_name in ipairs(sorted_keys(addr.pools or {})) do
		local p = addr.pools[pool_name]
		if is_plain_table(p) then
			cur:set('dhcp', pool_name, 'dhcp')
			uci_set(cur, 'dhcp', pool_name, 'interface', p.net or pool_name)
			uci_set(cur, 'dhcp', pool_name, 'start', p.start)
			uci_set(cur, 'dhcp', pool_name, 'limit', p.limit)
			uci_set(cur, 'dhcp', pool_name, 'leasetime', p.leasetime)
			if p.v4 and tostring(p.v4) ~= 'server' then
				uci_set(cur, 'dhcp', pool_name, 'ignore', '1')
			else
				uci_set(cur, 'dhcp', pool_name, 'ignore', nil)
			end
		end
	end

	-- domains
	for _, d in ipairs(addr.domains or {}) do
		if is_plain_table(d) and type(d.name) == 'string' and d.name ~= '' then
			local sec = cur:add('dhcp', 'domain')
			uci_set(cur, 'dhcp', sec, 'name', d.name)
			uci_set(cur, 'dhcp', sec, 'ip', d.ip)
		end
	end

	cur:commit('dhcp')
	return true, nil
end

local function apply_firewall(cur, desired)
	local fw = desired.firewall
	if not is_plain_table(fw) then return nil, 'missing desired.firewall' end

	wipe_pkg(cur, 'firewall')

	cur:set('firewall', 'defaults', 'defaults')
	for k, v in pairs(fw.defaults or {}) do
		uci_set(cur, 'firewall', 'defaults', k, v)
	end

	for _, zname in ipairs(sorted_keys(fw.zones or {})) do
		local z = fw.zones[zname]
		if is_plain_table(z) then
			cur:set('firewall', zname, 'zone')
			uci_set(cur, 'firewall', zname, 'name', zname)
			uci_set(cur, 'firewall', zname, 'input', z.input)
			uci_set(cur, 'firewall', zname, 'output', z.output)
			uci_set(cur, 'firewall', zname, 'forward', z.forward)
			uci_set(cur, 'firewall', zname, 'masq', z.masq)
			uci_set(cur, 'firewall', zname, 'mtu_fix', z.mtu_fix)
			uci_set_list(cur, 'firewall', zname, 'network', z.networks or {})
		end
	end

	for i, r in ipairs(fw.forwardings or {}) do
		if is_plain_table(r) then
			local sec = string.format('fwd_%s_%s_%d', tostring(r.src), tostring(r.dest), i)
			sec = sanitise_component(sec):gsub('%-', '_')
			cur:set('firewall', sec, 'forwarding')
			uci_set(cur, 'firewall', sec, 'src', r.src)
			uci_set(cur, 'firewall', sec, 'dest', r.dest)
		end
	end

	for i, r in ipairs(fw.rules or {}) do
		if is_plain_table(r) then
			local rid = (type(r.id) == 'string' and r.id ~= '') and r.id or ('rule_' .. tostring(i))
			rid = sanitise_component(rid):gsub('%-', '_')
			cur:set('firewall', rid, 'rule')
			uci_set(cur, 'firewall', rid, 'name', r.name or rid)
			uci_set(cur, 'firewall', rid, 'src', r.src)
			uci_set(cur, 'firewall', rid, 'dest', r.dest)
			uci_set(cur, 'firewall', rid, 'proto', r.proto)
			uci_set(cur, 'firewall', rid, 'src_port', r.src_port)
			uci_set(cur, 'firewall', rid, 'dest_port', r.dest_port)
			uci_set(cur, 'firewall', rid, 'icmp_type', r.icmp_type)
			uci_set(cur, 'firewall', rid, 'target', r.target)
		end
	end

	cur:commit('firewall')
	return true, nil
end

local function apply_mwan3(cur, desired)
	local mw = desired.multiwan
	if not is_plain_table(mw) then
		return true, nil
	end

	wipe_pkg(cur, 'mwan3')

	cur:set('mwan3', 'globals', 'globals')
	local g = mw.globals or {}
	uci_set(cur, 'mwan3', 'globals', 'mmx_mask', g.mark_mask)
	uci_set(cur, 'mwan3', 'globals', 'enabled', g.enabled ~= nil and (g.enabled and '1' or '0') or nil)
	uci_set(cur, 'mwan3', 'globals', 'logging', g.logging ~= nil and (g.logging and '1' or '0') or nil)
	uci_set(cur, 'mwan3', 'globals', 'loglevel', g.loglevel)

	-- interfaces (uplinks)
	for _, uname in ipairs(sorted_keys(mw.uplinks or {})) do
		local u = mw.uplinks[uname]
		if is_plain_table(u) then
			local sec = sid(uname)
			cur:set('mwan3', sec, 'interface')
			uci_set(cur, 'mwan3', sec, 'enabled', u.enabled ~= false and '1' or '0')
			uci_set(cur, 'mwan3', sec, 'family', u.family or 'ipv4')
			uci_set_list(cur, 'mwan3', sec, 'track_ip', u.probe or {})
			uci_set(cur, 'mwan3', sec, 'reliability', u.reliability)
			uci_set(cur, 'mwan3', sec, 'interval', u.interval)
			uci_set(cur, 'mwan3', sec, 'timeout', u.timeout)
			uci_set(cur, 'mwan3', sec, 'track_method', u.track)

			-- Optional future fields may be added by NET without forcing a backend
			-- redesign. We only write them when present.
			uci_set(cur, 'mwan3', sec, 'down', u.down)
			uci_set(cur, 'mwan3', sec, 'up', u.up)
			uci_set(cur, 'mwan3', sec, 'failure_interval', u.failure_interval)
			uci_set(cur, 'mwan3', sec, 'recovery_interval', u.recovery_interval)
			uci_set(cur, 'mwan3', sec, 'check_quality', u.check_quality)
			uci_set(cur, 'mwan3', sec, 'failure_latency', u.failure_latency)
			uci_set(cur, 'mwan3', sec, 'recovery_latency', u.recovery_latency)
			uci_set(cur, 'mwan3', sec, 'failure_loss', u.failure_loss)
			uci_set(cur, 'mwan3', sec, 'recovery_loss', u.recovery_loss)
		end
	end

	-- members
	for _, mid in ipairs(sorted_keys(mw.members or {})) do
		local m = mw.members[mid]
		if is_plain_table(m) then
			local sec = sid(mid)
			cur:set('mwan3', sec, 'member')
			uci_set(cur, 'mwan3', sec, 'interface', sid(m.uplink))
			uci_set(cur, 'mwan3', sec, 'metric', m.metric)
			uci_set(cur, 'mwan3', sec, 'weight', m.weight)
		end
	end

	-- policies
	for _, pname in ipairs(sorted_keys(mw.policies or {})) do
		local p = mw.policies[pname]
		if is_plain_table(p) then
			local sec = sid(pname)
			cur:set('mwan3', sec, 'policy')
			local use = {}
			for i = 1, #(p.use or {}) do
				use[i] = sid(p.use[i])
			end
			uci_set_list(cur, 'mwan3', sec, 'use_member', use)
			uci_set(cur, 'mwan3', sec, 'last_resort', p.last_resort)
		end
	end

	-- rules
	for i, r in ipairs(mw.rules or {}) do
		if is_plain_table(r) then
			local rid = (type(r.id) == 'string' and r.id ~= '') and r.id or ('rule_' .. tostring(i))
			local sec = 'rule_' .. sid(rid)
			cur:set('mwan3', sec, 'rule')
			uci_set(cur, 'mwan3', sec, 'use_policy', sid(r.policy))
			uci_set(cur, 'mwan3', sec, 'family', r.family)
			uci_set(cur, 'mwan3', sec, 'src_ip', r.src_ip)
			uci_set(cur, 'mwan3', sec, 'dest_ip', r.dest_ip)
			uci_set(cur, 'mwan3', sec, 'proto', r.proto)
			uci_set(cur, 'mwan3', sec, 'src_port', r.src_port)
			uci_set(cur, 'mwan3', sec, 'dest_port', r.dest_port)
			uci_set(cur, 'mwan3', sec, 'sticky', r.sticky)
			uci_set(cur, 'mwan3', sec, 'timeout', r.timeout)
		end
	end

	cur:commit('mwan3')
	return true, nil
end

local function reload_services(desired, host)
	local ok, err

	ok, err = cmd_ok('/etc/init.d/network', 'reload')
	if not ok then return nil, 'network reload failed: ' .. tostring(err) end

	ok, err = cmd_ok('/etc/init.d/dnsmasq', 'restart')
	if not ok then return nil, 'dnsmasq restart failed: ' .. tostring(err) end

	ok, err = cmd_ok('/etc/init.d/firewall', 'restart')
	if not ok then return nil, 'firewall restart failed: ' .. tostring(err) end

	-- Staging policy: write mwan3 config if desired.multiwan exists,
	-- but only apply/restart if installed and not in no_reload mode.
	if not (host and host.no_reload) and desired.multiwan then
		local ok1 = cmd_ok('sh', '-c', '[ -x /etc/init.d/mwan3 ]')
		if ok1 then
			ok, err = cmd_ok('/etc/init.d/mwan3', 'restart')
			if not ok then return nil, 'mwan3 restart failed: ' .. tostring(err) end
		else
			if host and host.log then
				host.log('info', { what = 'mwan3_not_applied', reason = 'init_script_missing' })
			end
		end
	end

	return true, nil
end

function M.new(host)
	host = host or {}

	local state_dir = host.state_dir or os.getenv('DEVICECODE_STATE_DIR') or '/tmp/devicecode-state'
	do
		local ok, err = mkdir_p(state_dir)
		if not ok and host.log then
			host.log('warn', { what = 'state_dir_mkdir_failed', dir = state_dir, err = err })
		end
	end

	-- If using an isolated confdir, ensure the directories exist and seed package files.
	if host.uci_confdir then
		local ok, err = mkdir_p(host.uci_confdir)
		if not ok then error('uci_confdir mkdir failed: ' .. tostring(err), 2) end
	end
	if host.uci_savedir then
		local ok, err = mkdir_p(host.uci_savedir)
		if not ok then error('uci_savedir mkdir failed: ' .. tostring(err), 2) end
	end

	-- Seed package files for isolated testing so libuci and the CLI agree.
	do
		local ok, err = ensure_pkg_file(host, 'network');  if not ok then error(err, 2) end
		ok, err = ensure_pkg_file(host, 'dhcp');           if not ok then error(err, 2) end
		ok, err = ensure_pkg_file(host, 'firewall');       if not ok then error(err, 2) end
		ok, err = ensure_pkg_file(host, 'mwan3');          if not ok then error(err, 2) end
	end

	local uci = require('uci')

	-- host.uci_confdir: directory containing UCI config files (alternative to /etc/config)
	-- host.uci_savedir: directory for UCI save/delta files (alternative to /tmp/.uci)
	local cur = uci.cursor(host.uci_confdir, host.uci_savedir)

	local self = {}

	function self:name() return 'openwrt' end

	function self:capabilities()
		return {
			state_store             = true,
			apply_net               = true,
			apply_wifi              = false,

			-- Runtime sensing.
			list_links              = true,
			probe_links             = true,
			read_link_counters      = true,

			-- Runtime live control.
			-- The methods exist below, but the OS-touching implementations for live
			-- shaping and live multipath are still stubs. Advertising them as false
			-- lets NET feature-gate safely.
			apply_link_shaping_live = false,
			apply_multipath_live    = false,
			persist_multipath_state = true,
		}
	end

	function self:dump(req, _msg)
		-- Simple diagnostic dump. Intended for inspection and debugging rather
		-- than as a stable high-rate data API.
		req = req or {}

		local packages = req.packages
		if type(packages) ~= 'table' or #packages == 0 then
			packages = { 'network', 'dhcp', 'firewall', 'mwan3' }
		end

		local out = {}
		for i = 1, #packages do
			local pkg = tostring(packages[i])
			local ok, txt, err = cmd_capture('uci', 'show', pkg)
			out[pkg] = {
				ok   = (ok == true),
				text = ok and txt or nil,
				err  = (ok ~= true) and tostring(err) or nil,
			}
		end

		return {
			ok        = true,
			backend   = 'openwrt',
			state_dir = state_dir,
			packages  = out,
		}
	end

	function self:read_state(req, _msg)
		local ns, key = req and req.ns, req and req.key
		if type(ns) ~= 'string' or ns == '' or type(key) ~= 'string' or key == '' then
			return { ok = false, err = 'ns and key must be non-empty strings' }
		end

		local path = state_path(state_dir, ns, key)
		local s, err = file.open(path, 'r')
		if not s then
			return { ok = true, found = false, err = tostring(err) }
		end

		local data, rerr = s:read_all()
		s:close()
		if rerr ~= nil then
			return { ok = false, err = tostring(rerr) }
		end
		return { ok = true, found = true, data = data or '' }
	end

	function self:write_state(req, _msg)
		local ns, key, data = req and req.ns, req and req.key, req and req.data
		if type(ns) ~= 'string' or ns == '' or type(key) ~= 'string' or key == '' then
			return { ok = false, err = 'ns and key must be non-empty strings' }
		end
		if type(data) ~= 'string' then
			return { ok = false, err = 'data must be a string' }
		end

		local dir = ns_dir(state_dir, ns)
		local ok, err = mkdir_p(dir)
		if not ok then
			return { ok = false, err = 'failed to create state dir: ' .. tostring(err) }
		end

		-- Atomic write: tmpfile in same directory then rename.
		local tmp, terr = file.tmpfile('rw-r--r--', dir)
		if not tmp then
			return { ok = false, err = 'tmpfile failed: ' .. tostring(terr) }
		end

		local w1, werr = tmp:write(data)
		if not w1 then
			tmp:close()
			return { ok = false, err = 'write failed: ' .. tostring(werr) }
		end
		tmp:flush()

		local final = state_path(state_dir, ns, key)
		local rok, rerr = tmp:rename(final)
		if not rok then
			tmp:close()
			return { ok = false, err = 'rename failed: ' .. tostring(rerr) }
		end

		local cok, cerr = tmp:close()
		if not cok then
			return { ok = false, err = 'close failed: ' .. tostring(cerr) }
		end

		return { ok = true }
	end

	function self:list_links(req, _msg)
		-- Read current OS-facing facts for one or more logical links.
		--
		-- NET uses this for:
		--   * link_id -> device resolution
		--   * current operstate / carrier / mtu
		--   * best-effort IPv4 and default gateway facts
		local ids = list_link_ids_from_req(req)
		local out = {}

		for i = 1, #ids do
			local link_id = ids[i]
			local dev, derr = resolve_network_device(cur, host, link_id)

			if not dev then
				out[link_id] = {
					ok       = false,
					link_id  = link_id,
					err      = tostring(derr),
					resolved = false,
				}
			else
				local facts, ferr = read_sysfs_link_facts(dev)
				if not facts then
					out[link_id] = {
						ok       = false,
						link_id  = link_id,
						device   = dev,
						err      = tostring(ferr),
						resolved = true,
					}
				else
					out[link_id] = {
						ok        = true,
						link_id   = link_id,
						device    = dev,
						resolved  = true,
						operstate = facts.operstate,
						carrier   = facts.carrier,
						mtu       = facts.mtu,
						ipv4      = read_ipv4_addr_for_device(dev),
						gateway   = read_default_route_for_device(dev),
					}
				end
			end
		end

		return {
			ok    = true,
			links = out,
		}
	end

	function self:probe_links(req, _msg)
		-- Execute one bounded probe round.
		--
		-- Expected request shape:
		--   {
		--     links = {
		--       wan = {
		--         method = "ping",
		--         reflectors = { "1.1.1.1", "1.0.0.1" },
		--         timeout_s = 2,
		--         count = 1,
		--       },
		--       ...
		--     }
		--   }
		--
		-- First implementation:
		--   * supports method="ping" only
		--   * uses the first reflector only
		--   * binds ping to the resolved device
		--
		-- This is enough for NET to own smoothing and health judgement while HAL
		-- remains the only OS-touching layer.
		if type(req) ~= 'table' or type(req.links) ~= 'table' then
			return { ok = false, err = 'req.links must be a table' }
		end

		local samples = {}

		for link_id, spec in pairs(req.links) do
			if type(link_id) ~= 'string' or link_id == '' then
				samples[link_id] = { ok = false, err = 'invalid link id' }
			elseif not is_plain_table(spec) then
				samples[link_id] = { ok = false, err = 'link spec must be a table' }
			else
				local dev, derr = resolve_network_device(cur, host, link_id)
				if not dev then
					samples[link_id] = { ok = false, err = tostring(derr) }
				else
					local method = spec.method or 'ping'
					local refs   = spec.reflectors
					local ref    = (type(refs) == 'table' and refs[1]) or nil

					if method ~= 'ping' then
						samples[link_id] = {
							ok     = false,
							device = dev,
							err    = 'unsupported probe method: ' .. tostring(method),
						}
					elseif type(ref) ~= 'string' or ref == '' then
						samples[link_id] = {
							ok     = false,
							device = dev,
							err    = 'no reflector configured',
						}
					else
						local rtt, perr = ping_rtt_ms_for_device(dev, ref, spec.timeout_s, spec.count)
						if not rtt then
							samples[link_id] = {
								ok        = false,
								device    = dev,
								reflector = ref,
								err       = tostring(perr),
							}
						else
							samples[link_id] = {
								ok        = true,
								device    = dev,
								reflector = ref,
								rtt_ms    = rtt,
							}
						end
					end
				end
			end
		end

		return {
			ok      = true,
			samples = samples,
		}
	end

	function self:read_link_counters(req, _msg)
		-- Read raw byte/packet counters for logical links.
		--
		-- NET should turn these into rates by differencing them across time.
		local ids = list_link_ids_from_req(req)
		local out = {}

		for i = 1, #ids do
			local link_id = ids[i]
			local dev, derr = resolve_network_device(cur, host, link_id)

			if not dev then
				out[link_id] = {
					ok  = false,
					err = tostring(derr),
				}
			else
				local base = '/sys/class/net/' .. tostring(dev) .. '/statistics/'
				local rx_bytes, rx_err = read_u64_file(base .. 'rx_bytes')
				local tx_bytes, tx_err = read_u64_file(base .. 'tx_bytes')
				local rx_packets = read_u64_file(base .. 'rx_packets')
				local tx_packets = read_u64_file(base .. 'tx_packets')

				if rx_bytes == nil or tx_bytes == nil then
					out[link_id] = {
						ok     = false,
						device = dev,
						err    = tostring(rx_err or tx_err or 'counter read failed'),
					}
				else
					out[link_id] = {
						ok         = true,
						device     = dev,
						rx_bytes   = rx_bytes,
						tx_bytes   = tx_bytes,
						rx_packets = rx_packets,
						tx_packets = tx_packets,
					}
				end
			end
		end

		return {
			ok    = true,
			links = out,
		}
	end

	function self:apply_link_shaping_live(req, _msg)
		-- Live shaping apply.
		--
		-- Expected request shape:
		--   {
		--     links = {
		--       wan = {
		--         mode = "cake",
		--         scope = "wan",
		--         up_kbit = 20000,
		--         down_kbit = 80000,
		--         overhead = 44,
		--         mpu = 84,
		--         ingress_ifb = "ifb4wan",
		--       },
		--     }
		--   }
		--
		-- This method is intentionally present before the actual tc helper is
		-- wired in. That lets NET and HAL settle the RPC and request shape first.
		--
		-- Final implementation should delegate to a dedicated tc helper module,
		-- which remains the only code touching tc.
		if type(req) ~= 'table' or type(req.links) ~= 'table' then
			return { ok = false, err = 'req.links must be a table', applied = false, changed = false }
		end

		if type(host.apply_link_shaping_live) == 'function' then
			return host.apply_link_shaping_live(req)
		end

		return {
			ok      = true,
			applied = true,
			changed = false,
			note    = 'apply_link_shaping_live not yet implemented in openwrt backend',
		}
	end

	function self:apply_multipath_live(req, _msg)
		-- Live multipath dataplane apply.
		--
		-- Expected request shape:
		--   {
		--     policy = "default",
		--     last_resort = "unreachable",
		--     members = {
		--       { link_id = "wan",  metric = 1, weight = 3 },
		--       { link_id = "wanb", metric = 1, weight = 1 },
		--     }
		--   }
		--
		-- This method should eventually:
		--   * rewrite the active mwan3 policy chain directly, or
		--   * bypass mwan3 and manage the dataplane primitive directly.
		--
		-- It should NOT restart mwan3 and should NOT rewrite the whole package.
		if type(req) ~= 'table' or type(req.members) ~= 'table' then
			return { ok = false, err = 'req.members must be an array', applied = false, changed = false }
		end

		if type(host.apply_multipath_live) == 'function' then
			return host.apply_multipath_live(req)
		end

		return {
			ok      = true,
			applied = true,
			changed = false,
			note    = 'apply_multipath_live not yet implemented in openwrt backend',
		}
	end

	function self:persist_multipath_state(req, _msg)
		-- Persist current live multipath state into UCI only.
		--
		-- This is intentionally separate from apply_multipath_live:
		--   * apply_multipath_live affects the current dataplane
		--   * persist_multipath_state affects future restart/reboot state
		local ok, err = persist_mwan3_live_state(cur, req)
		if not ok then
			return { ok = false, err = tostring(err), applied = false, changed = false }
		end

		return {
			ok      = true,
			applied = true,
			changed = true,
		}
	end

	function self:apply_net(desired, msg)
		if not is_plain_table(desired) then
			return { ok = false, err = 'desired must be a table', applied = false, changed = false }
		end
		if type(desired.schema) ~= 'string' or not desired.schema:match('^devicecode%.state/') then
			return { ok = false, err = 'unsupported desired schema', applied = false, changed = false }
		end

		-- Best-effort discard any pending edits.
		pcall(function()
			cur:revert('network')
			cur:revert('dhcp')
			cur:revert('firewall')
			cur:revert('mwan3')
		end)

		local ok, err

		ok, err = apply_network(cur, host, desired)
		if not ok then
			return { ok = false, err = 'apply_network: ' .. tostring(err), applied = false, changed = false }
		end

		ok, err = apply_dhcp(cur, desired)
		if not ok then
			return { ok = false, err = 'apply_dhcp: ' .. tostring(err), applied = false, changed = false }
		end

		ok, err = apply_firewall(cur, desired)
		if not ok then
			return { ok = false, err = 'apply_firewall: ' .. tostring(err), applied = false, changed = false }
		end

		ok, err = apply_mwan3(cur, desired)
		if not ok then
			return { ok = false, err = 'apply_mwan3: ' .. tostring(err), applied = false, changed = false }
		end

		if host and host.no_reload then
			return { ok = true, applied = true, changed = true, id = msg and msg.id or nil }
		end

		ok, err = reload_services(desired, host)
		if not ok then
			return { ok = false, err = tostring(err), applied = true, changed = true }
		end

		return { ok = true, applied = true, changed = true, id = msg and msg.id or nil }
	end

	return self
end

return M
