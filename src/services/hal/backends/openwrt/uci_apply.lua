-- services/hal/backends/openwrt/uci_apply.lua
--
-- Structural UCI apply helpers for the OpenWrt HAL backend.

local common = require 'services.hal.backends.openwrt.common'

local M = {}

local function apply_network(cur, host, desired)
	local net = desired.network
	if not common.is_plain_table(net) then return nil, 'missing desired.network' end

	common.wipe_pkg(cur, 'network')

	cur:set('network', 'globals', 'globals')
	local g = net.globals or {}
	common.uci_set(cur, 'network', 'globals', 'ula_prefix', g.ula_prefix)
	common.uci_set(cur, 'network', 'globals', 'packet_steering', g.packet_steering)
	common.uci_set(cur, 'network', 'globals', 'tcp_l3mdev', g.tcp_l3mdev)
	common.uci_set(cur, 'network', 'globals', 'udp_l3mdev', g.udp_l3mdev)
	common.uci_set(cur, 'network', 'globals', 'netifd_loglevel', g.netifd_loglevel)

	for _, lname in ipairs(common.sorted_keys(net.links or {})) do
		local l = net.links[lname]
		if common.is_plain_table(l) and l.kind == 'bridge' then
			local sec = common.uci_sec_id('dev_', lname)

			cur:set('network', sec, 'device')
			common.uci_set(cur, 'network', sec, 'name', lname)
			common.uci_set(cur, 'network', sec, 'type', 'bridge')
			common.uci_set_list(cur, 'network', sec, 'ports', l.ports or {})
			common.uci_set(cur, 'network', sec, 'bridge_empty', l.bridge_empty)

			if host and host.log then
				local got = cur:get('network', sec, 'name')
				if got ~= lname then
					host.log('warn', { what = 'bridge_section_not_visible', sec = sec, expected = lname, got = got })
				end
			end
		end
	end

	for _, ifid in ipairs(common.sorted_keys(net.nets or {})) do
		local i = net.nets[ifid]
		if common.is_plain_table(i) then
			cur:set('network', ifid, 'interface')
			common.uci_set(cur, 'network', ifid, 'proto', i.proto)

			common.uci_set(cur, 'network', ifid, 'auto', (i.auto == false) and '0' or '1')
			common.uci_set(cur, 'network', ifid, 'disabled', i.disabled and '1' or '0')
			common.uci_set(cur, 'network', ifid, 'force_link', i.force_link and '1' or nil)

			local dev = i.device or {}
			if type(dev.ref) == 'string' and dev.ref ~= '' then
				common.uci_set(cur, 'network', ifid, 'device', dev.ref)
			elseif type(dev.ifname) == 'string' and dev.ifname ~= '' then
				local resolved, rerr = common.resolve_ifname(host, dev.ifname)
				if resolved then
					common.uci_set(cur, 'network', ifid, 'device', resolved)
				else
					common.uci_set(cur, 'network', ifid, 'disabled', '1')
					common.uci_set(cur, 'network', ifid, 'device', nil)
					if host and host.log then
						host.log('warn', { what = 'ifname_unresolved', iface = ifid, selector = dev.ifname, err = rerr })
					end
				end
			end

			if i.proto == 'static' and common.is_plain_table(i.v4) then
				common.uci_set(cur, 'network', ifid, 'ipaddr', i.v4.addr)
				common.uci_set(cur, 'network', ifid, 'netmask', common.prefix_to_netmask(i.v4.prefix))
				common.uci_set(cur, 'network', ifid, 'gateway', i.v4.gw)
			else
				common.uci_set(cur, 'network', ifid, 'ipaddr', nil)
				common.uci_set(cur, 'network', ifid, 'netmask', nil)
				common.uci_set(cur, 'network', ifid, 'gateway', nil)
			end

			common.uci_set(cur, 'network', ifid, 'peerdns',
				(i.peerdns ~= nil) and (i.peerdns and '1' or '0') or nil)
			common.uci_set(cur, 'network', ifid, 'metric', i.metric)
			common.uci_set(cur, 'network', ifid, 'dns', i.dns)
		end
	end

	for _, r in ipairs(net.routes or {}) do
		if common.is_plain_table(r) then
			local sec = cur:add('network', 'route')
			common.uci_set(cur, 'network', sec, 'interface', r.net)
			common.uci_set(cur, 'network', sec, 'target', r.target)
			common.uci_set(cur, 'network', sec, 'gateway', r.via)
		end
	end

	cur:commit('network')
	return true, nil
end

local function apply_dhcp(cur, desired)
	local addr = desired.addressing
	if not common.is_plain_table(addr) then return nil, 'missing desired.addressing' end

	common.wipe_pkg(cur, 'dhcp')

	cur:set('dhcp', 'dnsmasq', 'dnsmasq')
	common.uci_set(cur, 'dhcp', 'dnsmasq', 'noresolv', '1')

	local dns = addr.dns or {}
	local plain = dns.plain or {}
	if not common.is_plain_table(plain) then plain = {} end

	common.uci_set(cur, 'dhcp', 'dnsmasq', 'cachesize', plain.cache_size)
	if type(plain.upstream_servers) == 'table' and #plain.upstream_servers > 0 then
		common.uci_set_list(cur, 'dhcp', 'dnsmasq', 'server', plain.upstream_servers)
	end

	for _, pool_name in ipairs(common.sorted_keys(addr.pools or {})) do
		local p = addr.pools[pool_name]
		if common.is_plain_table(p) then
			cur:set('dhcp', pool_name, 'dhcp')
			common.uci_set(cur, 'dhcp', pool_name, 'interface', p.net or pool_name)
			common.uci_set(cur, 'dhcp', pool_name, 'start', p.start)
			common.uci_set(cur, 'dhcp', pool_name, 'limit', p.limit)
			common.uci_set(cur, 'dhcp', pool_name, 'leasetime', p.leasetime)
			if p.v4 and tostring(p.v4) ~= 'server' then
				common.uci_set(cur, 'dhcp', pool_name, 'ignore', '1')
			else
				common.uci_set(cur, 'dhcp', pool_name, 'ignore', nil)
			end
		end
	end

	for _, d in ipairs(addr.domains or {}) do
		if common.is_plain_table(d) and type(d.name) == 'string' and d.name ~= '' then
			local sec = cur:add('dhcp', 'domain')
			common.uci_set(cur, 'dhcp', sec, 'name', d.name)
			common.uci_set(cur, 'dhcp', sec, 'ip', d.ip)
		end
	end

	cur:commit('dhcp')
	return true, nil
end

local function apply_firewall(cur, desired)
	local fw = desired.firewall
	if not common.is_plain_table(fw) then return nil, 'missing desired.firewall' end

	common.wipe_pkg(cur, 'firewall')

	cur:set('firewall', 'defaults', 'defaults')
	for k, v in pairs(fw.defaults or {}) do
		common.uci_set(cur, 'firewall', 'defaults', k, v)
	end

	for _, zname in ipairs(common.sorted_keys(fw.zones or {})) do
		local z = fw.zones[zname]
		if common.is_plain_table(z) then
			cur:set('firewall', zname, 'zone')
			common.uci_set(cur, 'firewall', zname, 'name', zname)
			common.uci_set(cur, 'firewall', zname, 'input', z.input)
			common.uci_set(cur, 'firewall', zname, 'output', z.output)
			common.uci_set(cur, 'firewall', zname, 'forward', z.forward)
			common.uci_set(cur, 'firewall', zname, 'masq', z.masq)
			common.uci_set(cur, 'firewall', zname, 'mtu_fix', z.mtu_fix)
			common.uci_set_list(cur, 'firewall', zname, 'network', z.networks or {})
		end
	end

	for i, r in ipairs(fw.forwardings or {}) do
		if common.is_plain_table(r) then
			local sec = string.format('fwd_%s_%s_%d', tostring(r.src), tostring(r.dest), i)
			sec = common.sanitise_component(sec):gsub('%-', '_')
			cur:set('firewall', sec, 'forwarding')
			common.uci_set(cur, 'firewall', sec, 'src', r.src)
			common.uci_set(cur, 'firewall', sec, 'dest', r.dest)
		end
	end

	for i, r in ipairs(fw.rules or {}) do
		if common.is_plain_table(r) then
			local rid = (type(r.id) == 'string' and r.id ~= '') and r.id or ('rule_' .. tostring(i))
			rid = common.sanitise_component(rid):gsub('%-', '_')
			cur:set('firewall', rid, 'rule')
			common.uci_set(cur, 'firewall', rid, 'name', r.name or rid)
			common.uci_set(cur, 'firewall', rid, 'src', r.src)
			common.uci_set(cur, 'firewall', rid, 'dest', r.dest)
			common.uci_set(cur, 'firewall', rid, 'proto', r.proto)
			common.uci_set(cur, 'firewall', rid, 'src_port', r.src_port)
			common.uci_set(cur, 'firewall', rid, 'dest_port', r.dest_port)
			common.uci_set(cur, 'firewall', rid, 'icmp_type', r.icmp_type)
			common.uci_set(cur, 'firewall', rid, 'target', r.target)
		end
	end

	cur:commit('firewall')
	return true, nil
end

local function apply_mwan3(cur, desired)
	local mw = desired.multiwan
	if not common.is_plain_table(mw) then
		return true, nil
	end

	common.wipe_pkg(cur, 'mwan3')

	cur:set('mwan3', 'globals', 'globals')
	local g = mw.globals or {}
	common.uci_set(cur, 'mwan3', 'globals', 'mmx_mask', g.mark_mask)
	common.uci_set(cur, 'mwan3', 'globals', 'enabled', g.enabled ~= nil and (g.enabled and '1' or '0') or nil)
	common.uci_set(cur, 'mwan3', 'globals', 'logging', g.logging ~= nil and (g.logging and '1' or '0') or nil)
	common.uci_set(cur, 'mwan3', 'globals', 'loglevel', g.loglevel)

	for _, uname in ipairs(common.sorted_keys(mw.uplinks or {})) do
		local u = mw.uplinks[uname]
		if common.is_plain_table(u) then
			local sec = common.sid(uname)
			cur:set('mwan3', sec, 'interface')
			common.uci_set(cur, 'mwan3', sec, 'enabled', u.enabled ~= false and '1' or '0')
			common.uci_set(cur, 'mwan3', sec, 'family', u.family or 'ipv4')
			common.uci_set_list(cur, 'mwan3', sec, 'track_ip', u.probe or {})
			common.uci_set(cur, 'mwan3', sec, 'reliability', u.reliability)
			common.uci_set(cur, 'mwan3', sec, 'interval', u.interval)
			common.uci_set(cur, 'mwan3', sec, 'timeout', u.timeout)
			common.uci_set(cur, 'mwan3', sec, 'track_method', u.track)
			common.uci_set(cur, 'mwan3', sec, 'down', u.down)
			common.uci_set(cur, 'mwan3', sec, 'up', u.up)
			common.uci_set(cur, 'mwan3', sec, 'failure_interval', u.failure_interval)
			common.uci_set(cur, 'mwan3', sec, 'recovery_interval', u.recovery_interval)
			common.uci_set(cur, 'mwan3', sec, 'check_quality', u.check_quality)
			common.uci_set(cur, 'mwan3', sec, 'failure_latency', u.failure_latency)
			common.uci_set(cur, 'mwan3', sec, 'recovery_latency', u.recovery_latency)
			common.uci_set(cur, 'mwan3', sec, 'failure_loss', u.failure_loss)
			common.uci_set(cur, 'mwan3', sec, 'recovery_loss', u.recovery_loss)
		end
	end

	for _, mid in ipairs(common.sorted_keys(mw.members or {})) do
		local m = mw.members[mid]
		if common.is_plain_table(m) then
			local sec = common.sid(mid)
			cur:set('mwan3', sec, 'member')
			common.uci_set(cur, 'mwan3', sec, 'interface', common.sid(m.uplink))
			common.uci_set(cur, 'mwan3', sec, 'metric', m.metric)
			common.uci_set(cur, 'mwan3', sec, 'weight', m.weight)
		end
	end

	for _, pname in ipairs(common.sorted_keys(mw.policies or {})) do
		local p = mw.policies[pname]
		if common.is_plain_table(p) then
			local sec = common.sid(pname)
			cur:set('mwan3', sec, 'policy')
			local use = {}
			for i = 1, #(p.use or {}) do
				use[i] = common.sid(p.use[i])
			end
			common.uci_set_list(cur, 'mwan3', sec, 'use_member', use)
			common.uci_set(cur, 'mwan3', sec, 'last_resort', p.last_resort)
		end
	end

	for i, r in ipairs(mw.rules or {}) do
		if common.is_plain_table(r) then
			local rid = (type(r.id) == 'string' and r.id ~= '') and r.id or ('rule_' .. tostring(i))
			local sec = 'rule_' .. common.sid(rid)
			cur:set('mwan3', sec, 'rule')
			common.uci_set(cur, 'mwan3', sec, 'use_policy', common.sid(r.policy))
			common.uci_set(cur, 'mwan3', sec, 'family', r.family)
			common.uci_set(cur, 'mwan3', sec, 'src_ip', r.src_ip)
			common.uci_set(cur, 'mwan3', sec, 'dest_ip', r.dest_ip)
			common.uci_set(cur, 'mwan3', sec, 'proto', r.proto)
			common.uci_set(cur, 'mwan3', sec, 'src_port', r.src_port)
			common.uci_set(cur, 'mwan3', sec, 'dest_port', r.dest_port)
			common.uci_set(cur, 'mwan3', sec, 'sticky', r.sticky)
			common.uci_set(cur, 'mwan3', sec, 'timeout', r.timeout)
		end
	end

	cur:commit('mwan3')
	return true, nil
end

function M.apply_net(self, desired, msg)
	local cur = self._cur
	local host = self._host

	if not common.is_plain_table(desired) then
		return { ok = false, err = 'desired must be a table', applied = false, changed = false }
	end
	if type(desired.schema) ~= 'string' or not desired.schema:match('^devicecode%.state/') then
		return { ok = false, err = 'unsupported desired schema', applied = false, changed = false }
	end

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

	ok, err = common.reload_services(desired, host)
	if not ok then
		return { ok = false, err = tostring(err), applied = true, changed = true }
	end

	return { ok = true, applied = true, changed = true, id = msg and msg.id or nil }
end

return M
