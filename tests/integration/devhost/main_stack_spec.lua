-- integration/devhost/main_stack_spec.lua

local cjson          = require 'cjson.safe'

local fibers         = require 'fibers'
local sleep          = require 'fibers.sleep'
local busmod         = require 'bus'

local runfibers      = require 'tests.support.run_fibers'
local probe          = require 'tests.support.bus_probe'
local fake_hal_mod   = require 'tests.support.fake_hal'
local diag           = require 'tests.support.stack_diag'

local mainmod        = require 'devicecode.main'
local config_service = require 'services.config'
local net_service    = require 'services.net'

local T = {}

local function config_timings()
	return {
		hal_wait_timeout_s       = 0.25,
		hal_wait_tick_s          = 0.01,
		heartbeat_s              = 60.0,
		persist_debounce_s       = 0.02,
		persist_max_delay_s      = 0.05,
		persist_retry_initial_s  = 0.02,
		persist_retry_max_s      = 0.05,
	}
end

local function net_timings()
	return {
		hal_wait_timeout_s = 0.25,
		hal_wait_tick_s    = 0.01,
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

local function wait_retained_payload_matching(conn, topic, pred, opts)
	opts = opts or {}

	local found = nil
	local ok = probe.wait_until(function()
		local ok2, payload = pcall(function()
			return probe.wait_payload(conn, topic, { timeout = 0.02 })
		end)

		if ok2 and pred(payload) then
			found = payload
			return true
		end

		return false
	end, {
		timeout  = opts.timeout or 0.75,
		interval = opts.interval or 0.01,
	})

	if ok then
		return found
	end

	return nil
end

local function make_service_loader(fake_hal)
	return function(name)
		if name == 'hal' then
			return {
				start = function(conn, opts)
					-- fake_hal:start(...) sets up the fake HAL service behaviour,
					-- but returns immediately. Under devicecode.main that would be
					-- treated as a fatal "service returned unexpectedly".
					-- Keep the service alive until its scope is cancelled.
					fake_hal:start(conn, {
						name = opts and opts.name or 'hal',
						env  = opts and opts.env  or 'dev',
					})

					while true do
						sleep.sleep(3600.0)
					end
				end,
			}
		elseif name == 'config' then
			return {
				start = function(conn, opts)
					return config_service.start(conn, {
						name    = opts and opts.name or 'config',
						env     = opts and opts.env  or 'dev',
						timings = config_timings(),
					})
				end,
			}
		elseif name == 'net' then
			return {
				start = function(conn, opts)
					return net_service.start(conn, {
						name    = opts and opts.name or 'net',
						env     = opts and opts.env  or 'dev',
						timings = net_timings(),
					})
				end,
			}
		end

		error('unexpected service name: ' .. tostring(name), 0)
	end
end

local function spawn_main(scope, bus, fake_hal, services_csv)
	local child, cerr = scope:child()
	assert(child ~= nil, tostring(cerr))

	local ok_spawn, err = scope:spawn(function()
		mainmod.run(child, {
			env            = 'dev',
			services_csv   = services_csv,
			bus            = bus,
			service_loader = make_service_loader(fake_hal),
		})
	end)
	assert(ok_spawn, tostring(err))

	return child
end

function T.devhost_main_boots_mini_stack_and_publishes_running_state()
	runfibers.run(function(scope)
		local bus  = busmod.new()
		local conn = bus:connect()

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

		local rec = diag.start(scope, bus, {
			{ label = 'obs',    topic = { 'obs', '#' } },
			{ label = 'svc',    topic = { 'svc', '#' } },
			{ label = 'config', topic = { 'config', '#' } },
			{ label = 'state',  topic = { 'state', '#' } },
		}, {
			max_records = 300,
		})

		spawn_main(scope, bus, fake_hal, 'hal,config,net')

		local main_state = wait_retained_payload_matching(conn, { 'obs', 'state', 'main' }, function(payload)
			return type(payload) == 'table'
				and payload.status == 'running'
				and type(payload.services) == 'table'
				and #payload.services == 3
				and payload.services[1] == 'hal'
				and payload.services[2] == 'config'
				and payload.services[3] == 'net'
		end, { timeout = 0.75 })

		if main_state == nil then
			error(diag.explain(
				'expected retained obs/state/main with running status',
				rec,
				fake_hal
			), 0)
		end

		local hal_state = wait_retained_payload_matching(conn, { 'obs', 'state', 'service', 'hal' }, function(payload)
			return type(payload) == 'table'
				and payload.service == 'hal'
				and payload.status == 'running'
		end, { timeout = 0.75 })
		assert(hal_state ~= nil, 'expected retained hal running state')

		local config_state = wait_retained_payload_matching(conn, { 'obs', 'state', 'service', 'config' }, function(payload)
			return type(payload) == 'table'
				and payload.service == 'config'
				and payload.status == 'running'
		end, { timeout = 0.75 })
		assert(config_state ~= nil, 'expected retained config running state')

		local net_state = wait_retained_payload_matching(conn, { 'obs', 'state', 'service', 'net' }, function(payload)
			return type(payload) == 'table'
				and payload.service == 'net'
				and payload.status == 'running'
		end, { timeout = 0.75 })
		assert(net_state ~= nil, 'expected retained net running state')

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
	end, { timeout = 1.25 })
end

function T.devhost_main_stack_propagates_config_update_to_second_apply()
	runfibers.run(function(scope)
		local bus      = busmod.new()
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
				write_state = scripted_replies(8, function()
					return { ok = true }
				end),
				apply_net = scripted_replies(8, function()
					return { ok = true, applied = true, changed = true }
				end),
				list_links = scripted_replies(8, function()
					return { ok = true, links = {} }
				end),
				read_link_counters = scripted_replies(8, function()
					return { ok = true, links = {} }
				end),
				apply_link_shaping_live = scripted_replies(8, function()
					return { ok = true, applied = true, changed = false }
				end),
				apply_multipath_live = scripted_replies(8, function()
					return { ok = true, applied = true, changed = false }
				end),
			},
		})

		local rec = diag.start(scope, bus, {
			{ label = 'obs',    topic = { 'obs', '#' } },
			{ label = 'svc',    topic = { 'svc', '#' } },
			{ label = 'config', topic = { 'config', '#' } },
			{ label = 'state',  topic = { 'state', '#' } },
		}, {
			max_records = 300,
		})

		spawn_main(scope, bus, fake_hal, 'hal,config,net')

		local main_ready = wait_retained_payload_matching(req_conn, { 'obs', 'state', 'main' }, function(payload)
			return type(payload) == 'table'
				and payload.status == 'running'
		end, { timeout = 0.75 })

		if main_ready == nil then
			error(diag.explain(
				'expected main stack to reach running state before publishing config updates',
				rec,
				fake_hal
			), 0)
		end

		local function publish_net_set(answer)
			req_conn:publish({ 'config', 'net', 'set' }, {
				data = minimal_net_cfg({
					answer = answer,
				}),
			})
		end

		local deadline1 = fibers.now() + 0.5
		while fibers.now() < deadline1 do
			publish_net_set(1)

			local seen1 = probe.wait_until(function()
				return #method_calls(fake_hal, 'apply_net') >= 1
			end, { timeout = 0.03, interval = 0.005 })

			if seen1 then
				break
			end

			sleep.sleep(0.01)
		end

		local seen_first = probe.wait_until(function()
			return #method_calls(fake_hal, 'apply_net') >= 1
		end, { timeout = 0.4, interval = 0.01 })

		assert(seen_first == true, 'expected first apply_net call')

		local deadline2 = fibers.now() + 0.5
		while fibers.now() < deadline2 do
			publish_net_set(2)

			local seen2 = probe.wait_until(function()
				return #method_calls(fake_hal, 'apply_net') >= 2
			end, { timeout = 0.03, interval = 0.005 })

			if seen2 then
				break
			end

			sleep.sleep(0.01)
		end

		local seen_second = probe.wait_until(function()
			return #method_calls(fake_hal, 'apply_net') >= 2
		end, { timeout = 0.4, interval = 0.01 })

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
