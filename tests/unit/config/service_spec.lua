-- tests/config_service_spec.lua

local fibers         = require 'fibers'
local sleep          = require 'fibers.sleep'
local busmod         = require 'bus'

local safe = require 'coxpcall'

local runfibers      = require 'tests.support.run_fibers'
local probe          = require 'tests.support.bus_probe'
local fake_hal_mod   = require 'tests.support.fake_hal'

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

function T.config_loads_from_hal_and_publishes_retained()
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
					{
						ok    = true,
						found = true,
						data  = [[{"net":{"rev":2,"data":{"schema":"devicecode.net/1","foo":"bar"}}}]],
					},
				},
			},
		})

		fake_hal:start(bus:connect(), { name = 'hal' })

		local ok_spawn, err = scope:spawn(function()
			config_service.start(bus:connect(), {
				name    = 'config',
				env     = 'dev',
				timings = config_timings(),
			})
		end)
		assert(ok_spawn, tostring(err))

		local payload = probe.wait_payload(conn, { 'cfg', 'net' }, { timeout = 0.5 })
		assert(type(payload) == 'table')
		assert(payload.rev == 2)
		assert(type(payload.data) == 'table')
		assert(payload.data.schema == 'devicecode.net/1')
		assert(payload.data.foo == 'bar')
	end, { timeout = 1.0 })
end

function T.config_accepts_set_and_persists_debounced()
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
					{ ok = true },
				},
			},
		})

		fake_hal:start(bus:connect(), { name = 'hal' })

		local ok_spawn, err = scope:spawn(function()
			config_service.start(bus:connect(), {
				name    = 'config',
				env     = 'dev',
				timings = config_timings(),
			})
		end)
		assert(ok_spawn, tostring(err))

		local req_conn = bus:connect()

		-- Retry call until the service has definitely bound and accepted it.
		local deadline = fibers.now() + 0.5
		local seen = false

		while fibers.now() < deadline do
			req_conn:call({ 'cmd', 'config', 'set' }, {
				service = 'net',
				data = {
					schema = 'devicecode.net/1',
					answer = 42,
				},
			}, { timeout = 0.02 })

			seen = probe.wait_until(function()
				local ok, payload = safe.pcall(function()
					return probe.wait_payload(conn, { 'cfg', 'net' }, { timeout = 0.02 })
				end)
				return ok
					and type(payload) == 'table'
					and payload.rev == 1
					and type(payload.data) == 'table'
					and payload.data.answer == 42
			end, { timeout = 0.03, interval = 0.005 })

			if seen then
				break
			end

			sleep.sleep(0.01)
		end

		assert(seen == true, 'expected retained cfg/net update')

		local persisted = probe.wait_until(function()
			for i = 1, #fake_hal.calls do
				if fake_hal.calls[i].method == 'write_state' then
					return true
				end
			end
			return false
		end, { timeout = 0.5, interval = 0.005 })

		assert(persisted == true, 'expected write_state to be called')

		local write_call = nil
		for i = 1, #fake_hal.calls do
			if fake_hal.calls[i].method == 'write_state' then
				write_call = fake_hal.calls[i]
				break
			end
		end

		assert(write_call ~= nil)
		assert(write_call.req.ns == 'config')
		assert(write_call.req.key == 'services')
		assert(type(write_call.req.data) == 'string')
	end, { timeout = 1.0 })
end

return T
