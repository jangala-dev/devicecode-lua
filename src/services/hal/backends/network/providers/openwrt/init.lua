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

local function build_network_changes(intent)
	local changes = {}
	local known = {}
	local segment_to_ifaces, iface_to_device = collect_interface_maps(intent)

	set_section(changes, 'network', 'globals', 'globals')
	known.globals = true

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
		set_option(changes, 'network', ifsec, 'device', iface_to_device[ifid])
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
	if type(routes) == 'table' then
		for i = 1, #routes do
			local r = routes[i]
			if is_plain_table(r) then
				local rsec = section_id('route', 'route_' .. tostring(i))
				known[rsec] = true
				set_section(changes, 'network', rsec, 'route')
				set_option(changes, 'network', rsec, 'interface', r.interface or r.net)
				set_option(changes, 'network', rsec, 'target', r.target)
				set_option(changes, 'network', rsec, 'gateway', r.gateway or r.via)
			end
		end
	end

	return changes, known, segment_to_ifaces
end

local function build_dhcp_changes(intent)
	local changes = {}
	local known = {}
	set_section(changes, 'dhcp', 'dnsmasq', 'dnsmasq')
	known.dnsmasq = true
	local dns = is_plain_table(intent.dns) and intent.dns or {}
	if dns.enabled ~= false then
		set_option(changes, 'dhcp', 'dnsmasq', 'domainneeded', '1')
		set_option(changes, 'dhcp', 'dnsmasq', 'boguspriv', '1')
		if type(dns.upstreams) == 'table' and #dns.upstreams > 0 then
			set_option(changes, 'dhcp', 'dnsmasq', 'server', dns.upstreams)
		end
	end

	for _, seg_id in ipairs(sorted_keys(intent.segments or {})) do
		local seg = intent.segments[seg_id]
		local dh = is_plain_table(seg.dhcp) and seg.dhcp or {}
		if dh.enabled == true then
			local sec = section_id('dhcp', seg_id)
			known[sec] = true
			set_section(changes, 'dhcp', sec, 'dhcp')
			set_option(changes, 'dhcp', sec, 'interface', seg_id)
			set_option(changes, 'dhcp', sec, 'start', dh.start or dh.range_start or 100)
			set_option(changes, 'dhcp', sec, 'limit', dh.limit or dh.range_limit or 150)
			set_option(changes, 'dhcp', sec, 'leasetime', dh.leasetime or dh.lease_time or '12h')
		elseif dh.enabled == false then
			local sec = section_id('dhcp', seg_id)
			known[sec] = true
			set_section(changes, 'dhcp', sec, 'dhcp')
			set_option(changes, 'dhcp', sec, 'interface', seg_id)
			set_option(changes, 'dhcp', sec, 'ignore', '1')
		end
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
	set_option(changes, 'firewall', 'defaults', 'input', defaults.input or 'REJECT')
	set_option(changes, 'firewall', 'defaults', 'output', defaults.output or 'ACCEPT')
	set_option(changes, 'firewall', 'defaults', 'forward', defaults.forward or 'REJECT')

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
	for _, zname in ipairs(sorted_keys(zone_to_networks)) do
		local zsec = section_id('zone', zname)
		local zspec = is_plain_table(zone_specs[zname]) and zone_specs[zname] or {}
		local nets = zone_to_networks[zname]
		table.sort(nets)
		known[zsec] = true
		set_section(changes, 'firewall', zsec, 'zone')
		set_option(changes, 'firewall', zsec, 'name', zname)
		set_option(changes, 'firewall', zsec, 'network', nets)
		set_option(changes, 'firewall', zsec, 'input', zspec.input or 'ACCEPT')
		set_option(changes, 'firewall', zsec, 'output', zspec.output or 'ACCEPT')
		set_option(changes, 'firewall', zsec, 'forward', zspec.forward or 'REJECT')
		set_option(changes, 'firewall', zsec, 'masq', bool_uci(zspec.masq))
		set_option(changes, 'firewall', zsec, 'mtu_fix', bool_uci(zspec.mtu_fix))
	end

	local policies = is_plain_table(fw.policies) and fw.policies or {}
	local n = 0
	for _, pid in ipairs(sorted_keys(policies)) do
		local p = policies[pid]
		if is_plain_table(p) and type(p.src) == 'string' and type(p.dest) == 'string' then
			n = n + 1
			local sec = section_id('fwd', pid .. '_' .. tostring(n))
			known[sec] = true
			set_section(changes, 'firewall', sec, 'forwarding')
			set_option(changes, 'firewall', sec, 'src', p.src)
			set_option(changes, 'firewall', sec, 'dest', p.dest)
		end
	end

	return changes, known
end

local function apply_package(mgr, pkg, changes, _known, restart_cmds)
	-- This first provider slice uses deterministic named sections and lets UCI
	-- replace existing values.  Later full reconciliation can add quiet deletion of
	-- stale generated sections once provider-owned markers are in place.
	return mgr:submit_op({
		config = pkg,
		changes = changes,
		restart_cmds = restart_cmds,
	})
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
		confdir = self.config.confdir or self.config.uci_confdir,
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
	local confdir = self.config.confdir or self.config.uci_confdir
	if confdir then
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
	local n_changes, n_known, segment_to_ifaces = build_network_changes(intent)
	local d_changes, d_known = build_dhcp_changes(intent)
	local f_changes, f_known = build_firewall_changes(intent, segment_to_ifaces)
	return op.always({
		ok = true,
		backend = 'openwrt',
		plan = {
			packages = {
				network = { changes = #n_changes, sections = count_keys(n_known) },
				dhcp = { changes = #d_changes, sections = count_keys(d_known) },
				firewall = { changes = #f_changes, sections = count_keys(f_known) },
			},
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

		local n_changes, n_known, segment_to_ifaces = build_network_changes(intent)
		local d_changes, d_known = build_dhcp_changes(intent)
		local f_changes, f_known = build_firewall_changes(intent, segment_to_ifaces)

		local ok, err, admitted = fibers.perform(apply_package(mgr, 'network', n_changes, n_known, {
			{ kind = 'reload', target = 'network' },
		}))
		if ok ~= true then return { ok = false, err = 'network UCI apply failed: ' .. tostring(err), admitted = admitted, backend = 'openwrt' } end
		ok, err, admitted = fibers.perform(apply_package(mgr, 'dhcp', d_changes, d_known, {
			{ kind = 'restart', target = 'dnsmasq' },
		}))
		if ok ~= true then return { ok = false, err = 'dhcp UCI apply failed: ' .. tostring(err), admitted = admitted, backend = 'openwrt' } end
		ok, err, admitted = fibers.perform(apply_package(mgr, 'firewall', f_changes, f_known, {
			{ kind = 'restart', target = 'firewall' },
		}))
		if ok ~= true then return { ok = false, err = 'firewall UCI apply failed: ' .. tostring(err), admitted = admitted, backend = 'openwrt' } end

		return {
			ok = true,
			applied = true,
			changed = true,
			backend = 'openwrt',
			intent_rev = intent.rev,
			packages = { 'network', 'dhcp', 'firewall' },
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

local function ubus_call(object, method, payload)
	payload = payload or {}
	local encoded = cjson.encode(payload)
	if type(encoded) ~= 'string' then return nil, 'ubus payload encode failed' end
	local ok, out, err = command_capture({ 'ubus', 'call', tostring(object), tostring(method), encoded })
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

local function normalise_mwan3_status(st)
	local out = {
		available = type(st) == 'table',
		interfaces = {},
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
			out.interfaces[ifid] = {
				interface = ifid,
				state = state,
				mwan3_status = rec.status,
				enabled = rec.enabled,
				running = rec.running,
				tracking = rec.tracking,
				up = rec.up,
				age = tonumber(rec.age),
				uptime = tonumber(rec.uptime),
				online = tonumber(rec.online),
				offline = tonumber(rec.offline),
				score = tonumber(rec.score),
				lost = tonumber(rec.lost),
				turn = tonumber(rec.turn),
				probes = probes,
				raw = copy_plain(rec),
			}
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
		local st, err = ubus_call('network.interface.' .. tostring(ifid), 'status', {})
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
		local st, err = ubus_call('network.device', 'status', { name = dev })
		if st then
			live.devices[dev] = normalise_device_status(dev, st)
		else
			append_error(live.errors, 'network.device status ' .. tostring(dev) .. ': ' .. tostring(err))
		end
	end
	local mwan, merr = ubus_call('mwan3', 'status', {})
	if mwan then
		observed.multiwan = normalise_mwan3_status(mwan)
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
	if req.live ~= false and self.config.enable_live_snapshot ~= false then
		augment_with_live_snapshot(self.config, observed, req, subject, trigger)
	end
	return observed, packages
end

function read_uci_packages(config)
	local ok, uci_or_err = pcall(require, 'uci')
	if not ok or not uci_or_err or type(uci_or_err.cursor) ~= 'function' then
		return nil, 'uci module unavailable'
	end
	local c = uci_or_err.cursor(config.confdir or config.uci_confdir, config.savedir or config.uci_savedir)
	local out = {}
	for _, pkg in ipairs({ 'network', 'dhcp', 'firewall' }) do
		if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end
		out[pkg] = type(c.get_all) == 'function' and c:get_all(pkg) or {}
	end
	return out, nil
end

function snapshot_from_packages(packages)
	local network = packages.network or {}
	local dhcp = packages.dhcp or {}
	local firewall = packages.firewall or {}

	local observed = {
		schema = 'devicecode.net.observed/1',
		segments = {},
		interfaces = {},
		dns = { enabled = true, upstreams = {} },
		dhcp = { pools = {} },
		firewall = { defaults = {}, zones = {}, policies = {} },
		routing = { routes = {} },
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
			observed.dns.upstreams = list_from_uci(sec.server)
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
			observed.firewall.defaults = {
				input = sec.input,
				output = sec.output,
				forward = sec.forward,
			}
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
