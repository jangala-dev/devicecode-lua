-- tests/devhost_stack_spec.lua

local cjson         = require 'cjson.safe'

local fibers        = require 'fibers'
local sleep         = require 'fibers.sleep'
local busmod        = require 'bus'

local runfibers     = require 'tests.support.run_fibers'
local probe         = require 'tests.support.bus_probe'
local fake_hal_mod  = require 'tests.support.fake_hal'

local config_service = require 'services.config'
local net_service    = require 'services.net'

local T = {}

local function config_timings()
	return {
		hal_wait_timeout_s        = 0.25,
		hal_wait_tick_s           = 0.01,
		heartbeat_s               = 60.0,
		persist_debounce_s        = 0.02,
		persist_max_delay_s       = 0.05,
		persist_retry_initial_s   = 0.02,
		persist_retry_max_s       = 0.05,
	}
end

local function minimal_net_cfg(extra)
	local cfg = {
		schema = 'devicecode.net/1',
		runtime = {
			net = {
				structural_debounce_s = 0.02,
				inventory_refresh_s   = 60.0,
				probe_interval_s      = 60.0,
				counter_interval_s    = 60.0,
				control_interval_s    = 60.0,
				persist_quiet_s       = 60.0,
			},
		},
	}

	if type(extra) == 'table' then
		for k, v in pairs(extra) do
			cfg[k] = v
		end
	end

	return cfg
end

local function encode_state_blob(t)
	local s, err = cjson.encode(t)
	assert(s ~= nil, tostring(err))
	return s
end

local function scripted_replies(n, factory)
	local out = {}
	for i = 1, n do
		out[i] = factory(i)
	end
	return out
end

local function spawn_config(scope, bus)
	local ok_spawn, err = scope:spawn(function()
		config_service.start(bus:connect(), {
			name    = 'config',
			env     = 'dev',
			timings = config_timings(),
		})
	end)
	assert(ok_spawn, tostring(err))
end

local function spawn_net(scope, bus)
	local ok_spawn, err = scope:spawn(function()
		net_service.start(bus:connect(), {
			name = 'net',
			env  = 'dev',
			timings = {
				hal_wait_timeout_s = 0.25,
				hal_wait_tick_s    = 0.01,
			},
		})
	end)
	assert(ok_spawn, tostring(err))
end

local function method_calls(fake_hal, method)
	local out = {}
	for i = 1, #fake_hal.calls do
		local c = fake_hal.calls[i]
		if c.method == method then
			out[#out + 1] = c
		end
	end
	return out
end

function T.devhost_booted_config_flows_into_net_and_applies_to_hal()
	runfibers.run(function(scope)
		local bus = busmod.new()

		local fake_hal = fake_hal_mod.new({
			backend = 'fakehal',
			caps = {
				read_state              = true,
				write_state             = true,
				apply_net               = true,
				list_links              = true,
				read_link_counters      = true,
				apply_link_shaping_live = true,
				apply_multipath_live    = true,
			},
			scripted = {
				read_state = {
					{
						ok    = true,
						found = true,
						data  = encode_state_blob({
							net = {
								rev  = 1,
								data = minimal_net_cfg(),
							},
						}),
					},
				},
				apply_net = {
					{ ok = true, applied = true, changed = true },
				},
				list_links = {
					{ ok = true, links = {} },
				},
				read_link_counters = {
					{ ok = true, links = {} },
				},
				apply_link_shaping_live = {
					{ ok = true, applied = true, changed = false },
				},
				apply_multipath_live = {
					{ ok = true, applied = true, changed = false },
				},
			},
		})

		fake_hal:start(bus:connect(), { name = 'hal' })
		spawn_config(scope, bus)
		spawn_net(scope, bus)

		local applied = probe.wait_until(function()
			return #method_calls(fake_hal, 'apply_net') >= 1
		end, { timeout = 0.75, interval = 0.01 })

		assert(applied == true, 'expected HAL apply_net call')

		local calls = method_calls(fake_hal, 'apply_net')
		assert(#calls >= 1)

		local call = calls[1]
		assert(type(call.req) == 'table')
		assert(call.req.rev == 1)
		assert(type(call.req.desired) == 'table')
		assert(call.req.desired.schema == 'devicecode.state/2.5')
		assert(type(call.req.desired.snapshot) == 'table')
		assert(call.req.desired.snapshot.rev == 1)

		-- These are not the main point of the test, but they show the stack
		-- continued into the first inventory/control passes.
		local list_calls = method_calls(fake_hal, 'list_links')
		assert(#list_calls >= 1)

		local ctr_calls = method_calls(fake_hal, 'read_link_counters')
		assert(#ctr_calls >= 1)
	end, { timeout = 1.0 })
end

function T.devhost_config_update_triggers_second_apply_revision()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local req_conn = bus:connect()

		local fake_hal = fake_hal_mod.new({
			backend = 'fakehal',
			caps = {
				read_state              = true,
				write_state             = true,
				apply_net               = true,
				list_links              = true,
				read_link_counters      = true,
				apply_link_shaping_live = true,
				apply_multipath_live    = true,
			},
			scripted = {
				read_state = {
					{ ok = true, found = false },
				},
				write_state = scripted_replies(4, function()
					return { ok = true }
				end),
				apply_net = scripted_replies(4, function()
					return { ok = true, applied = true, changed = true }
				end),
				list_links = scripted_replies(4, function()
					return { ok = true, links = {} }
				end),
				read_link_counters = scripted_replies(4, function()
					return { ok = true, links = {} }
				end),
				apply_link_shaping_live = scripted_replies(4, function()
					return { ok = true, applied = true, changed = false }
				end),
				apply_multipath_live = scripted_replies(4, function()
					return { ok = true, applied = true, changed = false }
				end),
			},
		})

		fake_hal:start(bus:connect(), { name = 'hal' })
		spawn_config(scope, bus)
		spawn_net(scope, bus)

		local function publish_net_set(answer)
			req_conn:publish({ 'config', 'net', 'set' }, {
				data = minimal_net_cfg({
					answer = answer,
				}),
			})
		end

		-- First revision.
		local deadline1 = fibers.now() + 0.5
		while fibers.now() < deadline1 do
			publish_net_set(1)

			local seen1 = probe.wait_until(function()
				return #method_calls(fake_hal, 'apply_net') >= 1
			end, { timeout = 0.03, interval = 0.005 })

			if seen1 then break end
			sleep.sleep(0.01)
		end

		local seen_first = probe.wait_until(function()
			return #method_calls(fake_hal, 'apply_net') >= 1
		end, { timeout = 0.25, interval = 0.01 })

		assert(seen_first == true, 'expected first apply_net call')

		-- Second revision.
		local deadline2 = fibers.now() + 0.5
		while fibers.now() < deadline2 do
			publish_net_set(2)

			local seen2 = probe.wait_until(function()
				return #method_calls(fake_hal, 'apply_net') >= 2
			end, { timeout = 0.03, interval = 0.005 })

			if seen2 then break end
			sleep.sleep(0.01)
		end

		local seen_second = probe.wait_until(function()
			return #method_calls(fake_hal, 'apply_net') >= 2
		end, { timeout = 0.25, interval = 0.01 })

		assert(seen_second == true, 'expected second apply_net call')

		local calls = method_calls(fake_hal, 'apply_net')
		assert(#calls >= 2)

		assert(type(calls[1].req) == 'table')
		assert(type(calls[2].req) == 'table')

		assert(calls[1].req.rev == 1)
		assert(calls[2].req.rev == 2)

		assert(type(calls[1].req.desired) == 'table')
		assert(type(calls[2].req.desired) == 'table')

		assert(calls[1].req.desired.snapshot.rev == 1)
		assert(calls[2].req.desired.snapshot.rev == 2)
	end, { timeout = 1.5 })
end

return T
