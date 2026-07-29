local cjson = require 'cjson.safe'
local fibers = require 'fibers'

local provider_loader = require 'services.hal.backends.network.provider'

local codec = require 'services.config.codec'
local net_config = require 'services.net.config'
local wired_config = require 'services.wired.config'
local device_config = require 'services.device.config'
local metrics_config = require 'services.metrics.config'

local T = {}

local function fail(msg)
	error(msg, 2)
end

local function ok(value, msg)
	if not value then fail(msg or 'expected truthy value') end
	return value
end

local function eq(actual, expected, msg)
	if actual ~= expected then
		fail((msg or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
	end
end

local function read_project_file(rel)
	local candidates = { rel, '../' .. rel }
	for i = 1, #candidates do
		local f = io.open(candidates[i], 'rb')
		if f then
			local data = f:read('*a')
			f:close()
			return data
		end
	end
	return nil
end

local function load_config()
	local text = ok(read_project_file('src/configs/bigbox-ss.json'), 'unable to read BigBox-SS config')
	local doc = ok(cjson.decode(text), 'BigBox-SS config must decode as JSON')
	return doc, text
end

function T.strict_blob_contains_only_ss_service_records()
	local doc, text = load_config()
	local decoded, err = codec.decode_blob_strict(text)
	ok(decoded, err)

	local expected = {
		device = true,
		gsm = true,
		hal = true,
		http = true,
		metrics = true,
		net = true,
		system = true,
		ui = true,
		wired = true,
	}
	for name, rec in pairs(decoded) do
		ok(expected[name], 'unexpected SS service config: ' .. tostring(name))
		expected[name] = nil
		eq(rec.rev, 1, name .. ' config revision')
		ok(type(rec.data.schema) == 'string' and rec.data.schema ~= '', name .. ' schema')
	end
	for name in pairs(expected) do
		fail('missing SS service config: ' .. name)
	end

	eq(doc.wifi, nil, 'SS must not configure Wi-Fi')
	eq(doc.fabric, nil, 'SS must not configure Fabric/UART')
	eq(doc.update, nil, 'SS must not configure the CM MCU updater')
	eq(doc.hal.data.wlan, nil, 'SS HAL must not configure WLAN')
	eq(doc.hal.data.uart, nil, 'SS HAL must not configure UART')
end

function T.network_preserves_ss_vlan_wan_and_shaping_policy()
	local doc = load_config()
	local intent, err = net_config.normalise(doc.net, { generation = 1 })
	ok(intent, err)

	eq(intent.product, 'bigbox-ss')
	eq(intent.segments.adm.vlan.id, 8)
	eq(intent.segments.jan.vlan.id, 32)
	eq(intent.segments.int.vlan.id, 100)
	eq(intent.segments.wan.vlan.id, 4)
	eq(intent.segments.adm.addressing.ipv4.cidr, '172.28.8.1/24')
	eq(intent.segments.jan.addressing.ipv4.cidr, '172.28.32.1/24')
	eq(intent.segments.int.addressing.ipv4.cidr, '172.28.100.1/24')

	local host = intent.segments.jan.shaping.host_default
	eq(host.mode, 'budgeted_peak')
	eq(host.download.sustained_rate, '6mbit')
	eq(host.download.peak_rate, '24mbit')
	eq(host.download.burst_budget, '1500k')
	eq(host.upload.sustained_rate, '3mbit')
	eq(host.upload.peak_rate, '12mbit')
	eq(host.upload.burst_budget, '750k')

	ok(intent.wan.members.wan)
	eq(intent.wan.members.modem_primary.source.id, 'primary')
	eq(intent.wan.members.modem_secondary.source.id, 'secondary')
	eq(intent.routing.routes.starlink_admin.interface, 'wan')
	eq(intent.routing.routes.starlink_admin.target, '192.168.100.1')
	eq(intent.dns.records['config.bigbox.home'].address, '172.28.8.1')
end

function T.hardware_model_is_single_nic_without_cm_components()
	local doc = load_config()
	local providers = doc.hal.data.wired.providers
	ok(providers['ss-local-wired'])
	eq(providers['cm5-local-wired'], nil)
	eq(providers['switch-main'], nil)
	eq(providers['ss-local-wired'].surfaces.eth0.attachment.mode, 'trunk')

	local wired, werr = wired_config.normalise(doc.wired, { generation = 1 })
	ok(wired, werr)
	ok(wired.surfaces['ss-eth0'])
	eq(wired.surfaces['ss-eth0'].attachment.mode, 'trunk')
	eq(wired.surfaces['switch-uplink-cm5'], nil)

	local catalogue, derr = device_config.to_catalogue(doc.device)
	ok(catalogue, derr)
	ok(doc.device.data.components['ss-host'])
	eq(doc.device.data.components.mcu, nil)
	eq(doc.device.data.components['switch-main'], nil)
	eq(doc.device.data.assembly.components['ss-local-wired'].observation.source[5], 'ss-local-wired')
	eq(doc.device.data.assembly.surfaces['ss-eth0'].observed_surface, 'eth0')
end

function T.gsm_usb_ui_and_metrics_are_ss_specific()
	local doc = load_config()
	local known = doc.gsm.data.modems.known
	eq(known[1].device, '/sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb1/1-1/1-1.2')
	eq(known[2].device, '/sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb1/1-1/1-1.4')
	eq(known[1].metrics_interval, 60)
	eq(known[2].metrics_interval, 60)
	eq(doc.gsm.data.modems.default.signal_freq, 10)

	eq(doc.system.data.usb3_enabled, false)
	eq(doc.ui.data.updates.upload.enabled, false)
	eq(doc.ui.data.updates.upload.component, 'ss-host')
	eq(doc.ui.data.updates.upload.create_job, false)
	eq(doc.ui.data.updates.upload.start_job, false)

	local metrics_ok, warnings, metrics_err = metrics_config.validate_config(doc.metrics)
	ok(metrics_ok, metrics_err)
	eq(#warnings, 0, 'SS metrics warnings')
	ok(doc.metrics.data.pipelines.speedtest)
	ok(doc.metrics.data.pipelines.hw_id)
	eq(doc.metrics.data.pipelines.num_sta, nil)
	eq(doc.metrics.data.pipelines.alloc, nil)
	eq(doc.metrics.data.pipelines.curr_time, nil)
end

function T.openwrt_provider_can_plan_and_apply_ss_intent()
	fibers.run(function()
		local doc = load_config()
		local intent, err = net_config.normalise(doc.net, { generation = 1 })
		ok(intent, err)

		local batch_text = {}
		local provider, perr = provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			platform = { segment_trunk = { ifname = 'eth0', protected = true } },
			shaper_run_cmd = function(argv)
				if argv[1] == 'tc' and argv[2] == '-batch' and type(argv[3]) == 'string' then
					local f = io.open(argv[3], 'rb')
					if f then
						batch_text[#batch_text + 1] = f:read('*a') or ''
						f:close()
					end
				end
				return true, nil
			end,
			shaper_run_restore = function()
				return true, nil, ''
			end,
		}, {})
		ok(provider, perr)

		local plan = fibers.perform(provider:plan_op({ intent = intent }))
		eq(plan.ok, true, plan.err)
		ok(plan.plan.packages.network.changes > 0, 'SS network plan must contain changes')
		ok(plan.plan.packages.dhcp.changes > 0, 'SS DHCP plan must contain changes')
		ok(plan.plan.packages.firewall.changes > 0, 'SS firewall plan must contain changes')

		local result = fibers.perform(provider:apply_op({ intent = intent }))
		eq(result.ok, true, result.err)
		ok(result.shaping and result.shaping.ok, 'SS shaping apply must succeed')
		ok(result.shaping.links and result.shaping.links.jan, 'SS JAN shaping result must be present')
		eq(result.shaping.links.jan.iface, 'br-jan')
		local commands = table.concat(batch_text, '\n')
		ok(commands:find('rate 6mbit', 1, true), 'SS download sustained rate must reach tc')
		ok(commands:find('rate 24mbit', 1, true), 'SS download peak rate must reach tc')
		ok(commands:find('rate 3mbit', 1, true), 'SS upload sustained rate must reach tc')
		ok(commands:find('rate 12mbit', 1, true), 'SS upload peak rate must reach tc')
		provider:terminate('test complete')
	end)
end


return T
