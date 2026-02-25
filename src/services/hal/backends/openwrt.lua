-- services/hal/backends/openwrt.lua
--
-- OpenWrt 21+ HAL backend using libuci-lua for configuration writes, and
-- fibers.io.{file,exec} for I/O and process execution.
--
-- Key properties:
--   * Replace semantics: applies full configs by wiping and recreating UCI packages.
--   * Testable: supports host.uci_confdir / host.uci_savedir to write UCI elsewhere.
--   * Staging: always writes mwan3 config when present, but only restarts it if installed.
--   * Safe UCI section ids: avoids '-' in section names (not reliably persisted by libuci on some images).

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
		f:close(); return true
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
	-- Important: section ids must not contain '-' on some libuci builds.
	for _, lname in ipairs(sorted_keys(net.links or {})) do
		local l = net.links[lname]
		if is_plain_table(l) and l.kind == 'bridge' then
			local sec = uci_sec_id('dev_', lname)

			cur:set('network', sec, 'device')
			uci_set(cur, 'network', sec, 'name', lname) -- kernel device name (may contain '-')
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
			-- Interface section name should already be safe (net compiler controls it).
			cur:set('network', ifid, 'interface')
			uci_set(cur, 'network', ifid, 'proto', i.proto)

			uci_set(cur, 'network', ifid, 'auto', (i.auto == false) and '0' or '1')
			uci_set(cur, 'network', ifid, 'disabled', i.disabled and '1' or '0')
			uci_set(cur, 'network', ifid, 'force_link', i.force_link and '1' or nil)

			local dev = i.device or {}
			if type(dev.ref) == 'string' and dev.ref ~= '' then
				-- dev.ref should be the kernel device name (e.g. 'br-adm').
				uci_set(cur, 'network', ifid, 'device', dev.ref)
			elseif type(dev.ifname) == 'string' and dev.ifname ~= '' then
				local resolved, rerr = resolve_ifname(host, dev.ifname)
				if resolved then
					uci_set(cur, 'network', ifid, 'device', resolved)
				else
					-- Safety: keep interface present but disabled.
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
			sec = sanitise_component(sec):gsub('%-', '_') -- keep conservative
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

	-- Use semantic ids for interfaces/members/policies; only rules get a prefix.
	local function sid(x) return sanitise_component(x):gsub('%-', '_') end

	-- interfaces (uplinks)
	for _, uname in ipairs(sorted_keys(mw.uplinks or {})) do
		local u = mw.uplinks[uname]
		if is_plain_table(u) then
			local sec = sid(uname) -- e.g. mdm0, wan
			cur:set('mwan3', sec, 'interface')
			uci_set(cur, 'mwan3', sec, 'enabled', u.enabled ~= false and '1' or '0')
			uci_set(cur, 'mwan3', sec, 'family', u.family or 'ipv4')
			uci_set_list(cur, 'mwan3', sec, 'track_ip', u.probe or {})
			uci_set(cur, 'mwan3', sec, 'reliability', u.reliability)
			uci_set(cur, 'mwan3', sec, 'interval', u.interval)
			uci_set(cur, 'mwan3', sec, 'timeout', u.timeout)
			uci_set(cur, 'mwan3', sec, 'track_method', u.track)
		end
	end

	-- members
	for _, mid in ipairs(sorted_keys(mw.members or {})) do
		local m = mw.members[mid]
		if is_plain_table(m) then
			local sec = sid(mid) -- e.g. mdm0_m1_w1
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
			local sec = sid(pname) -- e.g. default
			cur:set('mwan3', sec, 'policy')
			local use = {}
			for i = 1, #(p.use or {}) do
				use[i] = sid(p.use[i])
			end
			uci_set_list(cur, 'mwan3', sec, 'use_member', use)
			uci_set(cur, 'mwan3', sec, 'last_resort', p.last_resort)
		end
	end

	-- rules: prefix section ids to avoid colliding with policies (e.g. rule_default vs default)
	for i, r in ipairs(mw.rules or {}) do
		if is_plain_table(r) then
			local rid = (type(r.id) == 'string' and r.id ~= '') and r.id or ('rule_' .. tostring(i))
			local sec = 'rule_' .. sid(rid)
			cur:set('mwan3', sec, 'rule')
			uci_set(cur, 'mwan3', sec, 'use_policy', sid(r.policy))
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
		local ok, err = ensure_pkg_file(host, 'network'); if not ok then error(err, 2) end
		ok, err = ensure_pkg_file(host, 'dhcp'); if not ok then error(err, 2) end
		ok, err = ensure_pkg_file(host, 'firewall'); if not ok then error(err, 2) end
		ok, err = ensure_pkg_file(host, 'mwan3'); if not ok then error(err, 2) end
	end

	local uci = require('uci')

	-- host.uci_confdir: directory containing UCI config files (alternative to /etc/config)
	-- host.uci_savedir: directory for UCI save/delta files (alternative to /tmp/.uci)
	local cur = uci.cursor(host.uci_confdir, host.uci_savedir)

	local self = {}

	function self:name() return 'openwrt' end

	function self:capabilities()
		return { state_store = true, apply_net = true, apply_wifi = false }
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

	function self:apply_net(desired, msg)
		if not is_plain_table(desired) then
			return { ok = false, err = 'desired must be a table', applied = false, changed = false }
		end
		if type(desired.schema) ~= 'string' or not desired.schema:match('^devicecode%.state/') then
			return { ok = false, err = 'unsupported desired schema', applied = false, changed = false }
		end

		-- Best-effort discard any pending edits.
		pcall(function()
			cur:revert('network'); cur:revert('dhcp'); cur:revert('firewall'); cur:revert('mwan3')
		end)

		local ok, err

		ok, err = apply_network(cur, host, desired)
		if not ok then return { ok = false, err = 'apply_network: ' .. tostring(err), applied = false, changed = false } end

		ok, err = apply_dhcp(cur, desired)
		if not ok then return { ok = false, err = 'apply_dhcp: ' .. tostring(err), applied = false, changed = false } end

		ok, err = apply_firewall(cur, desired)
		if not ok then return { ok = false, err = 'apply_firewall: ' .. tostring(err), applied = false, changed = false } end

		ok, err = apply_mwan3(cur, desired)
		if not ok then return { ok = false, err = 'apply_mwan3: ' .. tostring(err), applied = false, changed = false } end

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
