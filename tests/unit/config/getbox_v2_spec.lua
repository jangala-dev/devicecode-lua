-- tests/unit/config/getbox_v2_spec.lua
--
-- Get Box V2 (Zbtlink ZBT-Z8106AX, MT7981) target config. Checks that
-- src/configs/getbox-v2.json loads through the config service, that every
-- section passes the validator its service uses, and that NET renders the
-- explicit (non-trunk) interface layout: front ports lan1-lan4 bridged into
-- the admin segment, wired WAN on eth1, one GSM modem uplink.

local fibers = require 'fibers'
local busmod = require 'bus'
local cjson = require 'cjson.safe'
local stdlib = require 'posix.stdlib'
local tablex = require 'shared.table'

local runfibers = require 'tests.support.run_virtual_fibers'
local probe = require 'tests.support.bus_probe'
local fake_hal_mod = require 'tests.support.fake_hal'

local T = {}

local TARGET = 'getbox-v2'
local LAN_PORTS = { 'lan1', 'lan2', 'lan3', 'lan4' }
local WAN_PORT = 'eth1'
-- Ports that must never be configured: the 2.5G CPU conduit and the
-- unidentified internal switch port.
local FORBIDDEN_PORTS = { eth0 = true, wwan = true }
local MODEM_IFNAME = 'wwan0'

local SECTIONS = { 'hal', 'net', 'wired', 'device', 'wifi', 'gsm', 'http', 'ui', 'system', 'metrics' }

local function fail(msg) error(msg or 'assertion failed', 2) end
local function ok(v, msg) if not v then fail(msg) end return v end
local function eq(a, b, msg)
	if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
end

local function read_project_file(rel)
	for _, path in ipairs({ rel, '../' .. rel }) do
		local f = io.open(path, 'rb')
		if f then local data = f:read('*a'); f:close(); return data end
	end
	return nil, 'unable to read ' .. rel
end

local function config_text()
	return ok(read_project_file('src/configs/' .. TARGET .. '.json'))
end

local function load_doc()
	return ok(cjson.decode(config_text()), TARGET .. '.json must decode')
end

local function find_change(changes, fields)
	for _, ch in ipairs(changes or {}) do
		local match = true
		for k, v in pairs(fields) do
			if ch[k] ~= v then match = false; break end
		end
		if match then return ch end
	end
	return nil
end

local function section_options(changes, section)
	local out = {}
	for _, ch in ipairs(changes or {}) do
		if ch.section == section and ch.value ~= nil then out[ch.option] = ch.value end
	end
	return out
end

local function list_text(v)
	if type(v) ~= 'table' then return tostring(v) end
	local out = {}
	for i = 1, #v do out[i] = tostring(v[i]) end
	return table.concat(out, ',')
end

local function sorted_list_text(v)
	local out = {}
	for i = 1, #(v or {}) do out[i] = tostring(v[i]) end
	table.sort(out)
	return table.concat(out, ',')
end

local function net_intent(doc)
	local net_config = require 'services.net.config'
	local intent, err = net_config.normalise(doc.net, { generation = 1 })
	return ok(intent, 'net config must normalise: ' .. tostring(err))
end

local function realised_intent(doc)
	local realiser = require 'services.net.intent_realiser'
	return realiser.realise(net_intent(doc), {
		gsm_uplinks = { primary = { linux = { ifname = MODEM_IFNAME } } },
	})
end

local function openwrt_provider(doc)
	local provider_loader = require 'services.hal.backends.network.provider'
	local cfg = tablex.deep_copy(doc.hal.data.network)
	cfg.allow_fake_uci = true
	return ok(provider_loader.new(cfg, {}))
end

local function with_env(name, value, fn)
	local prior = os.getenv(name)
	assert(stdlib.setenv(name, value))
	local ran, err = pcall(fn)
	if prior then stdlib.setenv(name, prior) else stdlib.setenv(name, nil) end
	if not ran then error(err, 0) end
end

function T.getbox_v2_loads_through_the_config_service()
	local config_service = require 'services.config'
	with_env('CONFIG_TARGET', TARGET, function()
		runfibers.run_auto(function(scope)
			local bus = busmod.new()
			local conn = bus:connect()
			local fake_hal = fake_hal_mod.new({
				backend = 'fakehal',
				caps = { read_state = true, write_state = true },
				scripted = { read_state = { { ok = true, found = true, data = config_text() } } },
			})
			fake_hal:start(bus:connect(), { name = 'hal' })

			ok(scope:spawn(function()
				config_service.start(bus:connect(), {
					name = 'config',
					env = 'dev',
					timings = { hal_wait_timeout_s = 0.25, heartbeat_s = 60.0 },
				})
			end))

			local doc = load_doc()
			for _, name in ipairs(SECTIONS) do
				local payload = probe.wait_payload(conn, { 'cfg', name }, { timeout = 0.5 })
				eq(payload.rev, 1, name .. ' rev')
				eq(payload.data.schema, doc[name].data.schema, name .. ' schema')
			end
			local read = nil
			for _, call in ipairs(fake_hal.calls) do
				if call.method == 'read_state' then read = call end
			end
			eq(ok(read, 'config should read its target file').req.key, TARGET)
		end, { timeout = 2.0 })
	end)
end

function T.getbox_v2_has_only_the_services_it_runs()
	local doc = load_doc()
	local want = {}
	for _, name in ipairs(SECTIONS) do want[name] = true; ok(doc[name], 'missing ' .. name .. ' section') end
	for name in pairs(doc) do
		ok(want[name], 'unexpected section ' .. tostring(name) .. ' (no MCU: no fabric or update)')
	end
	for name, rec in pairs(doc) do
		eq(rec.rev, 1, name .. ' rev')
		eq(type(rec.data), 'table', name .. ' data')
	end
end

function T.getbox_v2_sections_pass_their_service_validators()
	local doc = load_doc()

	net_intent(doc)

	local wired_config = require 'services.wired.config'
	ok(wired_config.normalise(doc.wired))

	local device_config = require 'services.device.config'
	local catalogue, cerr = device_config.to_catalogue(doc.device)
	ok(catalogue, 'device catalogue: ' .. tostring(cerr))
	ok(catalogue.components['gbv2-host'], 'host component')
	eq(catalogue.components['gbv2-host'].class, 'host')

	local ui_config = require 'services.ui.config'
	local ui, uerr = ui_config.normalise(doc.ui.data)
	ok(ui, 'ui config: ' .. tostring(uerr))
	eq(ui.updates.enabled, false, 'no MCU or host update path: UI upload stays off')

	local http_config = require 'services.http.config'
	ok(http_config.normalise(doc.http.data))

	local metrics_config = require 'services.metrics.config'
	local valid, _, merr = metrics_config.validate_config(doc.metrics)
	eq(valid, true, 'metrics config: ' .. tostring(merr))

	local gsm = require 'services.gsm'
	local gsm_cfg, gerr = gsm._test.normalize_config(doc.gsm.data)
	eq(gerr, '', 'gsm config')
	ok(gsm_cfg.modems)

	local system = require 'services.system'
	local sys_cfg, serr = system._test.validate_config(doc.system.data)
	eq(serr, '', 'system config')
	eq(sys_cfg.usb3_enabled, false)
	eq(system._test.usb_verb_for_config(TARGET, sys_cfg), nil, 'no USB3 hub control on Get Box V2')
end

function T.getbox_v2_hal_starts_only_managers_this_hardware_has()
	local doc = load_doc()
	local hal = doc.hal.data
	eq(hal.schema, 'devicecode.config/hal/1')
	for name, value in pairs(hal) do
		if name ~= 'schema' then
			eq(type(value), 'table', 'hal.' .. name)
			local loaded = pcall(require, 'services.hal.managers.' .. name)
			ok(loaded, 'hal.' .. name .. ' must name a HAL manager')
		end
	end
	for _, absent in ipairs({ 'usb', 'uart', 'artifact_store' }) do
		eq(hal[absent], nil, 'hal.' .. absent .. ' must stay off (no hub control, no MCU, no update staging)')
	end
	eq(hal.network.provider, 'openwrt')
	eq(hal.network.platform, nil, 'no segment trunk or shaping platform')
end

-- Root is an initramfs: durable state lives under /data, scratch under /tmp.
function T.getbox_v2_storage_roots_are_durable_under_data()
	local hal = load_doc().hal.data
	local roots = {}
	for _, fs in ipairs(hal.filesystem) do roots[fs.name] = fs.root end
	eq(roots.config, '/data/devicecode/configs')
	eq(roots.credentials, '/data/configs')
	eq(roots.state, '/tmp/devicecode-state')
	for _, store in ipairs(hal.control_store) do
		ok(store.root:find('^/data/'), 'control store ' .. store.name .. ' must be durable')
	end
	eq(#hal.control_store, 1)
	eq(hal.control_store[1].name, 'gsm')
end

function T.getbox_v2_keeps_secret_placeholders()
	local doc = load_doc()
	eq(doc.wifi.data.user_salt, '$USER_SALT')
	eq(doc.metrics.data.cloud_url, '$CLOUD_URL')
end

function T.getbox_v2_net_renders_lan_bridge_wired_wan_and_one_modem()
	local doc = load_doc()
	local intent = realised_intent(doc)
	fibers.run(function()
		local provider = openwrt_provider(doc)
		local plan = fibers.perform(provider:plan_op({ intent = intent }))
		eq(plan.ok, true, 'plan: ' .. tostring(plan.err))
		local net = plan.plan.raw_changes.network
		local names = plan.openwrt_names.names

		-- No VLAN trunk: no 802.1q devices at all.
		eq(find_change(net, { option = 'type', value = '8021q' }), nil, 'no VLAN devices')

		-- LAN: admin segment is a bridge over the four front ports.
		local adm_br = section_options(net, 'dev_bridge_adm')
		eq(adm_br.type, 'bridge')
		eq(adm_br.name, 'br-adm')
		eq(list_text(adm_br.ports), table.concat(LAN_PORTS, ','))
		local adm = section_options(net, 'adm')
		eq(adm.device, 'br-adm')
		eq(adm.proto, 'static')
		eq(adm.ipaddr, '172.28.8.1')
		eq(adm.netmask, '255.255.255.0')

		-- Jangala is Wi-Fi only: an empty bridge for the SSIDs to join.
		local jan_br = section_options(net, 'dev_bridge_jan')
		eq(jan_br.type, 'bridge')
		eq(jan_br.bridge_empty, '1')
		eq(jan_br.ports, nil, 'jan has no wired members')
		local jan = section_options(net, 'jan')
		eq(jan.device, 'br-jan')
		eq(jan.ipaddr, '172.28.32.1')

		-- WAN: DHCP directly on eth1, upstream DNS ignored.
		local wan = section_options(net, 'wan')
		eq(wan.device, WAN_PORT)
		eq(wan.proto, 'dhcp')
		eq(wan.peerdns, '0')

		-- Modem: the realised GSM uplink is its own DHCP interface.
		local modem_sec = names.logical_interface.modem_primary
		local modem = section_options(net, ok(modem_sec, 'modem_primary interface name'))
		eq(modem.device, MODEM_IFNAME)
		eq(modem.proto, 'dhcp')
		eq(names.logical_interface.modem_secondary, nil, 'single modem')

		-- Neither the CPU conduit nor the internal wwan switch port is used.
		for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
			for _, ch in ipairs(plan.plan.raw_changes[pkg]) do
				local values = type(ch.value) == 'table' and ch.value or { ch.value }
				for _, v in ipairs(values) do
					ok(not FORBIDDEN_PORTS[v], pkg .. '.' .. tostring(ch.section) .. '.' .. tostring(ch.option)
						.. ' must not reference ' .. tostring(v))
				end
			end
		end

		-- Firewall zones carry the right logical interfaces.
		local fw = plan.plan.raw_changes.firewall
		eq(sorted_list_text(section_options(fw, 'zone_lan').network), 'adm')
		eq(sorted_list_text(section_options(fw, 'zone_lan_rst').network), 'jan')
		eq(sorted_list_text(section_options(fw, 'zone_wan').network), sorted_list_text({ 'wan', modem_sec }))
		eq(section_options(fw, 'zone_wan').masq, 1)

		-- DHCP serves the LAN segments, never the WAN.
		local dhcp = plan.plan.raw_changes.dhcp
		local adm_dhcp = section_options(dhcp, 'dhcp_adm')
		eq(adm_dhcp.interface, 'adm')
		eq(adm_dhcp.start, 10)
		eq(adm_dhcp.limit, 240)
		eq(section_options(dhcp, 'dhcp_jan').interface, 'jan')
		eq(section_options(dhcp, 'dhcp_wan').ignore, '1')

		-- With no int segment, the admin instance must be the router's own
		-- resolver (it answers on loopback); no instance may be left without lo
		-- if all of them exclude it.
		local adm_instance = ok(adm_dhcp.instance, 'adm dnsmasq instance')
		local adm_dns = section_options(dhcp, adm_instance)
		eq(adm_dns.notinterface, nil, 'adm dnsmasq instance must answer on loopback')
		ok(list_text(adm_dns.interface):find('adm', 1, true), 'adm dnsmasq instance serves adm')
		eq(list_text(adm_dns.addnhosts), '/etc/jng/hosts/ads', 'only the ads list ships on Get Box')

		-- Multi-WAN: wired first, then the one modem.
		local mwan = plan.plan.raw_changes.mwan3
		ok(find_change(mwan, { option = 'interface', value = 'wan' }), 'mwan3 member for wan')
		ok(find_change(mwan, { option = 'interface', value = modem_sec }), 'mwan3 member for the modem')

		eq(plan.plan.domains.shaping.status, 'not_configured')
		eq(plan.plan.domains.discovery.status, 'not_configured')

		local result = fibers.perform(provider:apply_op({ intent = intent }))
		eq(result.ok, true, 'apply: ' .. tostring(result.err))
		eq(result.shaping, nil, 'no shaping on Get Box V2')
		provider:terminate('test complete')
	end)
end

function T.getbox_v2_wan_is_wired_then_one_modem()
	local intent = net_intent(load_doc())
	local members = intent.wan.members
	local ids = {}
	for id in pairs(members) do ids[#ids + 1] = id end
	table.sort(ids)
	eq(table.concat(ids, ','), 'modem_primary,wan')
	eq(members.wan.interface, 'wan')
	eq(members.wan.metric, 1)
	eq(members.modem_primary.metric, 2)
	eq(members.modem_primary.source.kind, 'gsm-uplink')
	eq(members.modem_primary.source.id, 'primary')
end

function T.getbox_v2_gsm_has_one_primary_modem_on_the_usb3_port()
	local gsm = load_doc().gsm.data
	eq(#gsm.modems.known, 1)
	local modem = gsm.modems.known[1]
	eq(modem.name, 'primary')
	eq(modem.id_field, 'device')
	eq(modem.device, '/sys/devices/platform/soc/11200000.usb/usb2/2-1')
	eq(gsm.apn_store.kind, 'control-store')
	eq(gsm.apn_store.id, 'gsm')
	eq(gsm.apn_store.import_v09_user_cfg, nil, 'new hardware has no v0.9 APNs to import')
end

function T.getbox_v2_wifi_uses_both_mt7981_radios_and_known_segments()
	local doc = load_doc()
	local radios = {}
	for _, r in ipairs(doc.hal.data.wlan.radios) do radios[r.name] = r end
	eq(radios.radio0.path, 'platform/soc/18000000.wifi')
	eq(radios.radio0.type, 'mac80211')
	eq(radios.radio1.path, 'platform/soc/18000000.wifi+1')
	eq(radios.radio1.type, 'mac80211')

	local wifi = doc.wifi.data
	local bands = {}
	for _, r in ipairs(wifi.radios) do
		ok(radios[r.name], 'wifi radio ' .. r.name .. ' must exist in hal.wlan')
		bands[r.name] = r.band
	end
	eq(bands.radio0, '2g')
	eq(bands.radio1, '5g')

	-- Wireless attaches each SSID to the OpenWrt interface named after its
	-- segment, so that segment must exist and be realised as an interface.
	-- The mainflux SSID's segment comes from the credentials file ("jng" is
	-- mapped to "adm").
	local intent = net_intent(doc)
	for _, ssid in ipairs(wifi.ssids) do
		local seg = ssid.segment or (ssid.mainflux_path and 'adm')
		ok(intent.segments[seg], 'ssid segment ' .. tostring(seg) .. ' must exist')
		ok(intent.interfaces[seg], 'ssid segment ' .. tostring(seg) .. ' must be an explicit interface')
		for _, r in ipairs(ssid.radios) do ok(radios[r], 'ssid radio ' .. r) end
	end
end

-- The wired service binds config surfaces to the static provider's ports
-- through the device assembly; nothing may be missing or contradictory.
function T.getbox_v2_wired_surfaces_bind_to_the_static_ports_without_violations()
	local wired_service = require 'services.wired.service'
	local wired_topics = require 'services.wired.topics'
	local device_config = require 'services.device.config'
	local static_provider = require 'services.hal.backends.wired.providers.static'

	local doc = load_doc()
	local catalogue = ok(device_config.to_catalogue(doc.device))
	local intent = net_intent(doc)
	local providers = doc.hal.data.wired.providers
	local provider_id = 'gbv2-local-wired'
	local provider_cfg = tablex.deep_copy(ok(providers[provider_id], 'static wired provider'))
	provider_cfg.poll = nil
	local provider = ok(static_provider.new(provider_cfg, { provider_id = provider_id }))

	runfibers.run_auto(function(scope)
		local snapshot = fibers.perform(provider:snapshot_op({}))
		local b = busmod.new()
		local writer = b:connect()
		local reader = b:connect()

		writer:retain({ 'state', 'net', 'segments' }, { rev = 1, segments = intent.segments })
		writer:retain({ 'state', 'device', 'assembly' }, catalogue.assembly)
		local raw = { 'raw', 'host', 'wired', 'provider', provider_id }
		writer:retain({ raw[1], raw[2], raw[3], raw[4], raw[5], 'status' }, snapshot.status)
		writer:retain({ raw[1], raw[2], raw[3], raw[4], raw[5], 'state', 'surfaces' }, { surfaces = snapshot.surfaces })
		writer:retain({ 'cfg', 'wired' }, doc.wired)

		local child = assert(scope:child())
		assert(child:spawn(function(svc_scope)
			wired_service.run(svc_scope, { conn = b:connect(), service_id = 'test-wired' })
		end))

		for i, port in ipairs(LAN_PORTS) do
			local s = probe.wait_retained_payload(reader, wired_topics.surface('lan-' .. i), { timeout = 1.5 })
			eq(s.availability.state, 'available', 'lan-' .. i)
			eq(s.source.observed_surface, port)
			eq(s.attachment.mode, 'access')
			eq(s.attachment.segment, 'adm')
		end
		local wan = probe.wait_retained_payload(reader, wired_topics.surface('wan'), { timeout = 1.5 })
		eq(wan.availability.state, 'available')
		eq(wan.source.observed_surface, WAN_PORT)
		eq(wan.role, 'wan-uplink')
		eq(wan.attachment.segment, 'wan')

		local violations = probe.wait_retained_payload(reader, wired_topics.violations(), { timeout = 1.0 })
		eq(#(violations.violations or {}), 0, 'wired violations: ' .. tostring(cjson.encode(violations.violations)))

		child:cancel('test complete')
		fibers.perform(child:join_op())
	end, { timeout = 3.0 })
end

return T
