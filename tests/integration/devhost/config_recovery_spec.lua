-- integration/devhost/config_recovery_spec.lua

local cjson          = require 'cjson.safe'

local busmod         = require 'bus'

local runfibers      = require 'tests.support.run_fibers'
local probe          = require 'tests.support.bus_probe'
local fake_hal_mod   = require 'tests.support.fake_hal'
local diag           = require 'tests.support.stack_diag'

local config_service = require 'services.config'

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

local function decode_json(s)
	local obj, err = cjson.decode(s)
	assert(obj ~= nil, tostring(err))
	return obj
end

function T.devhost_config_degrades_on_persist_failure_then_recovers()
	runfibers.run(function(scope)
		local bus  = busmod.new()
		local conn = bus:connect()

		local fake_hal = fake_hal_mod.new({
			backend = 'fakehal',
			caps = {
				read_state  = true,
				write_state = true,
			},
			scripted = {
				read_state = {
					{ ok = true, found = false },
				},
				write_state = {
					{ ok = false, err = 'disk full' },
					{ ok = true },
				},
			},
		})

		local rec = diag.start(scope, bus, {
			{ label = 'obs',    topic = { 'obs', '#' } },
			{ label = 'svc',    topic = { 'svc', '#' } },
			{ label = 'cfg',    topic = { 'cfg', '#' } },
		}, {
			max_records = 300,
		})

		fake_hal:start(bus:connect(), { name = 'hal' })

		local status_events = {}

		local ok_collector, cerr = scope:spawn(function()
			local sub = conn:subscribe({ 'svc', 'config', 'status' }, {
				queue_len = 64,
				full      = 'drop_oldest',
			})

			while true do
				local msg = sub:recv()
				if not msg then
					return
				end
				status_events[#status_events + 1] = msg.payload
			end
		end)
		assert(ok_collector, tostring(cerr))

		local ok_spawn, err = scope:spawn(function()
			config_service.start(bus:connect(), {
				name    = 'config',
				env     = 'dev',
				timings = config_timings(),
			})
		end)
		assert(ok_spawn, tostring(err))

		local config_ready = probe.wait_until(function()
			for i = 1, #status_events do
				local p = status_events[i]
				if type(p) == 'table' and p.state == 'running' then
					return true
				end
			end
			return false
		end, { timeout = 0.75, interval = 0.01 })

		if not config_ready then
			error(diag.explain(
				'expected config service to reach running state before publishing config set',
				rec,
				fake_hal
			), 0)
		end

		local req_conn = bus:connect()
		req_conn:publish({ 'config', 'net', 'set' }, {
			data = {
				schema = 'devicecode.net/1',
				answer = 42,
			},
		})

		local degraded_index = nil
		local saw_degraded = probe.wait_until(function()
			for i = 1, #status_events do
				local p = status_events[i]
				if type(p) == 'table' and p.state == 'degraded' and tostring(p.reason) == 'persist_failed' then
					degraded_index = i
					return true
				end
			end
			return false
		end, { timeout = 0.75, interval = 0.01 })

		if not saw_degraded then
			error(diag.explain(
				'expected config service to enter degraded state after failed write_state',
				rec,
				fake_hal
			), 0)
		end

		local saw_recovered_running = probe.wait_until(function()
			if degraded_index == nil then
				return false
			end

			for i = degraded_index + 1, #status_events do
				local p = status_events[i]
				if type(p) == 'table' and p.state == 'running' then
					return true
				end
			end
			return false
		end, { timeout = 0.75, interval = 0.01 })

		if not saw_recovered_running then
			error(diag.explain(
				'expected config service to recover to running state after retry succeeds',
				rec,
				fake_hal
			), 0)
		end

		local writes = {}
		for i = 1, #fake_hal.calls do
			local c = fake_hal.calls[i]
			if c.method == 'write_state' then
				writes[#writes + 1] = c
			end
		end

		assert(#writes >= 2, 'expected at least two write_state attempts')

		assert(type(writes[1].req) == 'table')
		assert(type(writes[2].req) == 'table')
		assert(type(writes[1].req.data) == 'string')
		assert(type(writes[2].req.data) == 'string')

		local blob1 = decode_json(writes[1].req.data)
		local blob2 = decode_json(writes[2].req.data)

		assert(type(blob1.net) == 'table')
		assert(type(blob2.net) == 'table')
		assert(blob1.net.rev == 1)
		assert(blob2.net.rev == 1)
		assert(type(blob1.net.data) == 'table')
		assert(type(blob2.net.data) == 'table')
		assert(blob1.net.data.answer == 42)
		assert(blob2.net.data.answer == 42)
	end, { timeout = 1.5 })
end

return T
