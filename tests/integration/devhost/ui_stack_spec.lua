-- integration/devhost/ui_stack_spec.lua

local cjson          = require 'cjson.safe'

local fibers         = require 'fibers'
local sleep          = require 'fibers.sleep'
local busmod         = require 'bus'

local safe = require 'coxpcall'

local runfibers      = require 'tests.support.run_fibers'
local probe          = require 'tests.support.bus_probe'
local fake_hal_mod   = require 'tests.support.fake_hal'
local diag           = require 'tests.support.stack_diag'

local mainmod        = require 'devicecode.main'
local config_service = require 'services.config'
local net_service    = require 'services.net'
local ui_service     = require 'services.ui'

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
		local ok2, payload = safe.pcall(function()
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

local function make_service_loader(bus, fake_hal, ui_api_box)
	return function(name)
		if name == 'hal' then
			return {
				start = function(conn, opts)
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
		elseif name == 'ui' then
			return {
				start = function(conn, opts)
					return ui_service.start(conn, {
						name = opts and opts.name or 'ui',
						env  = opts and opts.env  or 'dev',

						connect = function(principal)
							return bus:connect({ principal = principal })
						end,

						verify_login = function(username, password)
							if username == 'admin' and password == 'secret' then
								return {
									kind  = 'user',
									id    = 'admin',
									roles = { 'admin' },
								}, nil
							end
							return nil, 'invalid credentials'
						end,

						run_http = function(_, api, _)
							ui_api_box.api = api
							while true do
								sleep.sleep(3600.0)
							end
						end,
					})
				end,
			}
		end

		error('unexpected service name: ' .. tostring(name), 0)
	end
end

local function spawn_main(scope, bus, fake_hal, services_csv, ui_api_box)
	local child, cerr = scope:child()
	assert(child ~= nil, tostring(cerr))

	local ok_spawn, err = scope:spawn(function()
		mainmod.run(child, {
			env            = 'dev',
			services_csv   = services_csv,
			bus            = bus,
			service_loader = make_service_loader(bus, fake_hal, ui_api_box),
		})
	end)
	assert(ok_spawn, tostring(err))

	return child
end

function T.devhost_ui_controls_real_stack_via_login_config_and_rpc()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local conn     = bus:connect()
		local ui_api   = { api = nil }

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
				dump                    = true,
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
				dump = {
					{
						ok      = true,
						backend = 'fakehal',
						packages = {
							network = { ok = true, text = 'network.example' },
						},
					},
				},
			},
		})

		local rec = diag.start(scope, bus, {
			{ label = 'obs',    topic = { 'obs', '#' } },
			{ label = 'svc',    topic = { 'svc', '#' } },
			{ label = 'config', topic = { 'config', '#' } },
		}, {
			max_records = 400,
		})

		spawn_main(scope, bus, fake_hal, 'hal,config,net,ui', ui_api)

		local main_ready = wait_retained_payload_matching(conn, { 'obs', 'state', 'main' }, function(payload)
			return type(payload) == 'table'
				and payload.status == 'running'
		end, { timeout = 0.75 })

		if main_ready == nil then
			error(diag.explain(
				'expected main stack to reach running state',
				rec,
				fake_hal
			), 0)
		end

		local api_ready = probe.wait_until(function()
			return ui_api.api ~= nil
		end, { timeout = 0.75, interval = 0.01 })

		if not api_ready then
			error(diag.explain(
				'expected ui API capture via run_http hook',
				rec,
				fake_hal
			), 0)
		end

		local audit_sub = conn:subscribe({ 'obs', 'audit', 'ui', 'login' }, {
			queue_len = 4,
			full      = 'reject_newest',
		})

		local login, lerr = ui_api.api.login('admin', 'secret')
		assert(login ~= nil, tostring(lerr))
		assert(type(login.session_id) == 'string' and login.session_id ~= '')

		local audit_msg, aerr = audit_sub:recv()
		assert(audit_msg ~= nil, tostring(aerr))
		assert(type(audit_msg.payload) == 'table')
		assert(audit_msg.payload.user == 'admin')

		local cfg_out, cerr = ui_api.api.config_set(login.session_id, 'net', minimal_net_cfg({
			answer = 42,
		}))
		assert(cfg_out ~= nil, tostring(cerr))
		assert(cfg_out.ok == true)

		local applied = probe.wait_until(function()
			return #method_calls(fake_hal, 'apply_net') >= 1
		end, { timeout = 0.75, interval = 0.01 })

		if not applied then
			error(diag.explain(
				'expected NET to drive HAL apply_net after ui config_set',
				rec,
				fake_hal
			), 0)
		end

		local apply_calls = method_calls(fake_hal, 'apply_net')
		assert(#apply_calls >= 1)
		assert(type(apply_calls[1].req) == 'table')
		assert(apply_calls[1].req.rev == 1)

		local dump_out, derr = ui_api.api.rpc_call(login.session_id, 'hal', 'dump', {
			packages = { 'network' },
		}, 0.5)

		assert(dump_out ~= nil, tostring(derr))
		assert(dump_out.ok == true)
		assert(dump_out.backend == 'fakehal')
		assert(type(dump_out.packages) == 'table')
		assert(type(dump_out.packages.network) == 'table')
		assert(dump_out.packages.network.ok == true)

		local dump_calls = method_calls(fake_hal, 'dump')
		assert(#dump_calls >= 1)
	end, { timeout = 1.5 })
end

return T
