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

function tests.test_provider_watch_op_does_not_use_private_run_scope()
	local src = read_source('src/services/hal/backends/network/providers/openwrt/init.lua')
	local body = src:match('function Provider:watch_op%b()%s*(.-)\nfunction Provider:ingest_observation')
	ok(body, 'watch_op body not found')
	if body:find('run_scope_op', 1, true) then
		fail('watch_op must not use run_scope_op; it starts long-lived observer workers in caller scope')
	end
	ok(body:find('op.guard', 1, true), 'watch_op should be an immediate guard op')
end

return tests
