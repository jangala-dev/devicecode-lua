-- tests/unit/hal/openwrt_network_observer_spec.lua

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'

local observer_mod = require 'services.hal.backends.network.providers.openwrt.observer'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function ok(v, msg) if not v then fail(msg) end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end

function tests.test_observer_coalesces_wakeups_then_snapshots()
	fibers.run(function (scope)
		local emitted = {}
		local snapshots = {}
		local obs = ok(observer_mod.new({
			debounce_s = 0.01,
			enable_socket = false,
			enable_ubus = false,
			initial_snapshot = false,
			snapshot = function (subject, trigger)
				snapshots[#snapshots + 1] = { subject = subject, trigger = trigger }
				return {
					ok = true,
					backend = 'test',
					observed = {
						schema = 'devicecode.net.observed/1',
						interfaces = { wan = { id = 'wan', enabled = true } },
						segments = {},
					},
				}
			end,
			emit = function (ev)
				emitted[#emitted + 1] = ev
				return true
			end,
		}))
		ok(obs:start(scope))
		obs:ingest({ source = 'hotplug', directory = 'iface', env = { ACTION = 'ifup', INTERFACE = 'wan' } })
		obs:ingest({ source = 'ubus', payload = { action = 'ifupdate', interface = 'wan' } })
		fibers.perform(sleep.sleep_op(0.05))
		eq(#snapshots, 1)
		eq(#emitted, 1)
		eq(emitted[1].kind, 'interface_changed')
		eq(emitted[1].subject, 'interface:wan')
		eq(emitted[1].observed.interfaces.wan.enabled, true)
		obs:terminate('test complete')
	end)
end

local function read_source(relpath)
	local candidates = {
		relpath,
		'../' .. relpath,
		'../../' .. relpath,
	}

	for i = 1, #candidates do
		local f = io.open(candidates[i], 'r')
		if f then
			local src = f:read('*a')
			f:close()
			return src, candidates[i]
		end
	end

	fail('source file not found: ' .. tostring(relpath))
end


function tests.test_provider_installs_default_hotplug_and_mwan3_hooks()
	local src = read_source('src/services/hal/backends/network/providers/openwrt/init.lua')
	ok(src:find('install_observer_hooks(self)', 1, true), 'provider should install observer hooks before starting observer')
	ok(src:find('/etc/hotplug.d/iface', 1, true), 'iface hotplug hook path expected')
	ok(src:find('/etc/hotplug.d/net', 1, true), 'net hotplug hook path expected')
	ok(src:find('/etc/mwan3.user', 1, true), 'mwan3.user hook path expected')
	ok(src:find('cfg.install_observer_hooks == false', 1, true), 'hook installation should remain explicitly disableable')
	ok(src:find('skipped:fake_uci', 1, true), 'fake UCI tests should not touch host /etc by default')
	ok(src:find('source_tree_hotplug_sender_path', 1, true), 'hook sender path should be derived from the running source tree by default')
	ok(src:find('logger %-t devicecode%-net%-observe'), 'generated hooks should leave syslog diagnostics when forwarding fails')
	ok(src:find("hooks_ok == true and 'info'", 1, true), 'successful hook installation should be visible at info level')
end

function tests.test_provider_watch_op_does_not_use_private_run_scope()
	local src = read_source('src/services/hal/backends/network/providers/openwrt/init.lua')
	local body = src:match('function Provider:watch_op%b()%s*(.-)\nfunction Provider:ingest_observation')
	ok(body, 'watch_op body not found')
	if body:find('run_scope_op', 1, true) then
		fail('watch_op must not use run_scope_op; it starts long-lived observer workers in caller scope')
	end
	ok(body:find('op.guard', 1, true), 'watch_op should be an immediate guard op')
end


function tests.test_generated_hooks_pass_event_variables_explicitly_to_sender()
	local provider = require 'services.hal.backends.network.providers.openwrt.init'
	local src = read_source('src/services/hal/backends/network/providers/openwrt/init.lua')
	ok(src:find('--ACTION="${ACTION:-}"', 1, true), 'hook should pass ACTION explicitly')
	ok(src:find('--INTERFACE="${INTERFACE:-}"', 1, true), 'hook should pass INTERFACE explicitly')
	ok(src:find('socket missing:', 1, true), 'hook should log missing observer socket')
	ok(src:find('send failed source=', 1, true), 'hook should log sender failure diagnostics')
	local block = provider._test.mwan3_user_block({ observer_socket_path = '/tmp/devicecode.sock', hotplug_sender_path = '/tmp/hotplug_send.lua' })
	ok(block:find('connected', 1, true), 'mwan3.user block should include connected events')
	ok(block:find('disconnected', 1, true), 'mwan3.user block should include disconnected events')
end

function tests.test_hotplug_sender_bootstraps_source_tree_lib_and_vendor_package_paths()
	local src = read_source('src/services/hal/backends/network/providers/openwrt/hotplug_send.lua')
	ok(src:find('bootstrap_package_path', 1, true), 'hotplug sender should bootstrap its Lua package path')
	ok(src:find("/lib/?.lua", 1, true), 'hotplug sender should add flattened production lib path')
	ok(src:find("/lib/?/init.lua", 1, true), 'hotplug sender should add flattened production lib init path')
	ok(src:find('vendor/lua%-fibers/src'), 'hotplug sender should retain development lua-fibers path')
	ok(src:find('vendor/lua%-trie/src'), 'hotplug sender should retain development lua-trie src path')
	ok(src:find('split_sender_path', 1, true), 'hotplug sender should derive roots from its own path')
end

function tests.test_observer_logs_mwan3_trigger_ingress_at_info_level()
	local src = read_source('src/services/hal/backends/network/providers/openwrt/observer.lua')
	ok(src:find('network_observer_mwan3_trigger', 1, true), 'mwan3 socket ingress should be visible at info level')
	ok(src:find('network_observer_hotplug_trigger', 1, true), 'iface/net hotplug socket ingress should be visible at info level')
end

return tests
