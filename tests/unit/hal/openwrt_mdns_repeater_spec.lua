local fibers = require 'fibers'
local cjson = require 'cjson.safe'
local provider_mod = require 'services.hal.backends.network.providers.openwrt.init'
local mdns = require 'services.hal.backends.network.providers.openwrt.mdns_repeater'
local names = require 'services.hal.backends.network.providers.openwrt.names'
local tests = {}

local function eq(a, b) assert(a == b, 'expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
local function fixture(source, destination)
	source, destination = source or 'adm', destination or 'jan'
	return {
		schema = 'devicecode.net.intent/1', interfaces = {},
		segments = {
			[source] = { vlan = { id = 8 }, addressing = { ipv4 = {
				mode = 'static', cidr = '172.28.8.1/24',
				reserved_ranges = { shared_devices = { from = '172.28.8.250', to = '172.28.8.254' } },
			} } },
			[destination] = { vlan = { id = 32 }, addressing = { ipv4 = { mode = 'static', cidr = '172.28.32.1/24' } } },
		},
		dns = { service_discovery = { shared_devices = {
			enabled = true, source_segment = source, advertise_to = { destination },
			address_range = 'shared_devices', family = 'ipv4',
			services = { ipp = { type = '_ipp._tcp', protocol = 'tcp', ports = { 631 } } },
		} } },
	}
end
local function config()
	return { allow_fake_uci = true, platform = { segment_trunk = { ifname = 'eth0' } }, enable_observer = false }
end
local function options(plan)
	local out = {}
	for _, change in ipairs(plan.plan.raw_changes.mdns_repeater) do
		if change.value ~= nil then out[change.option] = change.value end
	end
	return out
end
local function with_plan(intent, callback, cfg)
	fibers.run(function()
		local provider = assert(provider_mod.new(cfg or config()))
		local plan = fibers.perform(provider:plan_op({ intent = intent }))
		callback(plan, provider)
		provider:terminate('test complete')
	end)
end

function tests.test_generated_devices_exact_whitelist_and_capabilities()
	local pairs_to_test = { { 'adm', 'jan' }, { 'administration_with_a_long_semantic_name', 'visitors_with_a_long_name' } }
	for _, pair in ipairs(pairs_to_test) do
		local intent = fixture(pair[1], pair[2])
		with_plan(intent, function(plan)
			assert(plan.ok, plan.err)
			local opts, allocated = options(plan), names.allocate(intent, config())
			eq(opts.interface[1], allocated:bridge(pair[1]))
			eq(opts.interface[2], allocated:bridge(pair[2]))
			assert(#opts.interface[1] <= 15)
			eq(#opts.whitelist, 6)
			for i = 1, 5 do eq(opts.whitelist[i], '172.28.8.' .. (249 + i) .. '/32') end
			eq(opts.whitelist[6], '172.28.32.0/24')
			local discovery = plan.plan.domains.discovery
			eq(discovery.status, 'implemented')
			eq(discovery.backend, 'mdns_repeater')
			eq(discovery.capabilities.range_filter, 'source_ip')
			eq(discovery.capabilities.service_filter, false)
			eq(discovery.capabilities.port_filter, false)
			eq(discovery.capabilities.directional, false)
		end)
	end
end

function tests.test_explicit_bridge_uses_interface_allocation_and_effective_client_subnet()
	local intent = fixture()
	intent.interfaces.client_bridge = {
		kind = 'bridge', segment = 'jan', members = { 'eth2' },
		addressing = { ipv4 = { mode = 'static', cidr = '10.0.2.17/23' } },
	}
	with_plan(intent, function(plan)
		assert(plan.ok, plan.err)
		local opts = options(plan)
		eq(opts.interface[2], names.allocate(intent, config()):bridge('client_bridge'))
		eq(opts.whitelist[6], '10.0.2.0/23')
	end)
end

function tests.test_disabled_and_absent_policy_clear_generated_lists()
	for _, absent in ipairs({ false, true }) do
		local intent = fixture()
		if absent then intent.dns.service_discovery = nil
		else intent.dns.service_discovery.shared_devices.enabled = false end
		with_plan(intent, function(plan)
			assert(plan.ok, plan.err)
			local opts = options(plan)
			eq(opts.enabled, '0')
			eq(opts.interface, nil)
			eq(opts.whitelist, nil)
			eq(plan.plan.domains.discovery.status, 'not_configured')
		end)
	end
end

function tests.test_range_changes_change_policy()
	local intent = fixture()
	intent.segments.adm.addressing.ipv4.reserved_ranges.shared_devices = { from = '172.28.8.251', to = '172.28.8.252' }
	with_plan(intent, function(plan)
		assert(plan.ok, plan.err)
		local opts = options(plan)
		eq(#opts.whitelist, 3)
		eq(opts.whitelist[1], '172.28.8.251/32')
		eq(opts.whitelist[2], '172.28.8.252/32')
	end)
end

function tests.test_unsupported_topologies_fail_planning_clearly()
	local cases = {
		function(i) i.dns.service_discovery.another = i.dns.service_discovery.shared_devices end,
		function(i) i.dns.service_discovery.shared_devices.advertise_to = { 'jan', 'adm' } end,
		function(i) i.segments.jan.enabled = false end,
		function(i) i.segments.jan.addressing.ipv4.cidr = '172.28.8.5/24' end,
		function(i) i.segments.adm.addressing.ipv4.reserved_ranges.shared_devices.from = '172.28.8.230' end,
		function(i) i.segments.adm.vlan = nil end,
		function(i) i.segments.jan.addressing.ipv4 = { mode = 'dhcp' } end,
	}
	for _, change in ipairs(cases) do
		local intent = fixture()
		change(intent)
		with_plan(intent, function(plan) eq(plan.ok, false); assert(type(plan.err) == 'string') end)
	end
end

function tests.test_discovery_does_not_change_firewall_rendering()
	local file = assert(io.open('../src/configs/bigbox-v1-cm-2.json'))
	local doc = assert(cjson.decode(file:read('*a'))); file:close()
	local net = require 'services.net.config'
	local intent = assert(net.normalise((net.extract_payload(doc.net))))
	with_plan(intent, function(plan, provider)
		assert(plan.ok, plan.err)
		local before = plan.plan.raw_changes.firewall
		intent.dns.service_discovery = nil
		local after = fibers.perform(provider:plan_op({ intent = intent })).plan.raw_changes.firewall
		eq(#before, #after)
		for index, value in ipairs(before) do
			for key, field in pairs(value) do
				if type(field) == 'table' then eq(table.concat(field, ','), table.concat(after[index][key], ','))
				else eq(field, after[index][key]) end
			end
		end
	end)
end

function tests.test_activation_failure_restores_policy_and_reactivates_previous_services()
	fibers.run(function()
		local cfg, commands, failed, fail_always = config(), {}, false, false
		local provider
		cfg.run_cmd = function(argv)
			commands[#commands + 1] = argv
			if argv[1] == '/bin/sh' then
				local current = provider._uci_manager._cursor:get_all('mdns_repeater').main
				if current.enabled == '1' and (fail_always or (current.whitelist[1] == '172.28.8.251/32' and not failed)) then
					failed = true
					return nil, 'synthetic mdns activation failure'
				end
			end
			return true
		end
		local data = {}
		local cursor = {
			get_all = function(_, pkg) return cjson.decode(cjson.encode(data[pkg] or {})) end,
			set = function(_, pkg, section, option, value)
				data[pkg] = data[pkg] or {}
				if value == nil then data[pkg][section] = { ['.type'] = option }
				else data[pkg][section][option] = value end
				return true
			end,
			delete = function(_, pkg, section) data[pkg][section] = nil; return true end,
			commit = function() return true end,
		}
		cfg.uci_manager = assert(require('services.hal.backends.openwrt.uci_manager').new({
			cursor = cursor, run_cmd = cfg.run_cmd,
		}))
		provider = assert(provider_mod.new(cfg))
		local intent = fixture()
		assert(fibers.perform(provider:apply_op({ intent = intent })).ok)
		eq(cursor:get_all('mdns_repeater').main.whitelist[1], '172.28.8.250/32')
		eq(commands[1][1], '/etc/init.d/network')
		eq(commands[3][1], '/etc/init.d/firewall')
		eq(commands[5][1], '/bin/sh')
		commands = {}
		intent.segments.adm.addressing.ipv4.reserved_ranges.shared_devices.from = '172.28.8.251'
		local result = fibers.perform(provider:apply_op({ intent = intent }))
		eq(result.ok, false)
		eq(result.status, 'failed_rolled_back')
		eq(result.rollback.reactivated, true)
		eq(#commands, 10)
		eq(cursor:get_all('mdns_repeater').main.whitelist[1], '172.28.8.250/32')
		fail_always = true
		result = fibers.perform(provider:apply_op({ intent = intent }))
		eq(result.status, 'failed_rollback_failed')
		eq(result.rollback.reactivated, false)
		fail_always = false
		intent.dns.service_discovery = nil
		assert(fibers.perform(provider:apply_op({ intent = intent })).ok)
		local cleared = cursor:get_all('mdns_repeater').main
		eq(cleared.enabled, '0')
		eq(cleared.whitelist, nil)
		eq(cleared.interface, nil)
		provider:terminate('test complete')
	end)
end

function tests.test_activation_requires_firmware_contract_and_snapshot_does_not_claim_liveness()
	local command = mdns.activation_command()
	assert(command[3]:find('source-whitelist-v1', 1, true))
	eq(command.wait, true)
	local snapshot = mdns.snapshot({ main = { enabled = '1', interface = { 'data1', 'data2' } } })
	eq(snapshot.configured, true)
	eq(snapshot.running, nil)
	eq(snapshot.capabilities.service_filter, false)
end

return tests
