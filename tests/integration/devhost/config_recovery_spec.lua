local cjson          = require 'cjson.safe'
local busmod         = require 'bus'
local safe           = require 'coxpcall'

local runfibers      = require 'tests.support.run_fibers'
local probe          = require 'tests.support.bus_probe'
local fake_hal_mod   = require 'tests.support.fake_hal'
local test_diag      = require 'tests.support.test_diag'

local config_service = require 'services.config'

local T = {}

local function decode_json(s)
	local v, err = cjson.decode(s)
	assert(v ~= nil, tostring(err))
	return v
end

local function config_timings()
	return {
		hal_wait_timeout_s       = 0.25,
		heartbeat_s              = 60.0,
		persist_debounce_s       = 0.02,
		persist_max_delay_s      = 0.05,
		persist_retry_initial_s  = 0.02,
		persist_retry_max_s      = 0.05,
	}
end

function T.devhost_config_recovers_after_failed_persist_retry()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local fake_hal = fake_hal_mod.new({
			backend = 'fakehal',
			caps = { read_state = true, write_state = true },
			scripted = {
				read_state = { { ok = true, found = false } },
				write_state = {
					{ ok = false, err = 'disk full' },
					{ ok = true },
				},
			},
		})
		fake_hal:start(bus:connect(), { name = 'hal' })

		local status_events = {}
		local diag = test_diag.for_stack(scope, bus, { config = true, obs = true, max_records = 300, fake_hal = fake_hal })
		test_diag.add_calls(diag, 'status_events', status_events)
		test_diag.add_subsystem(diag, 'device', {
			summary_fn = test_diag.retained_fn(bus:connect(), { 'state', 'device' }),
		})

		local conn = bus:connect()
		local sub = conn:subscribe({ 'svc', 'config', 'status' }, { queue_len = 32 })
		local ok_collector, cerr = scope:spawn(function()
			while true do
				local msg = sub:recv()
				if not msg then return end
				status_events[#status_events + 1] = msg.payload
			end
		end)
		assert(ok_collector, tostring(cerr))

		local ok_spawn, err = scope:spawn(function()
			config_service.start(bus:connect(), { name = 'config', env = 'dev', timings = config_timings() })
		end)
		assert(ok_spawn, tostring(err))

		local ready = probe.wait_until(function()
			for i = 1, #status_events do
				local p = status_events[i]
				if type(p) == 'table' and p.state == 'running' then return true end
			end
			return false
		end, { timeout = 0.75, interval = 0.01 })
		if not ready then diag:fail('expected config to reach running') end

		local req_conn = bus:connect()
		local reply, rerr = req_conn:call({ 'cmd', 'config', 'set' }, {
			service = 'net',
			data = { schema = 'devicecode.net/1', answer = 42 },
		}, { timeout = 0.25 })
		assert(reply ~= nil, tostring(rerr))
		assert(reply.ok == true)

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
		if not saw_degraded then diag:fail('expected degraded after failed persist') end

		local saw_recovered = probe.wait_until(function()
			if degraded_index == nil then return false end
			for i = degraded_index + 1, #status_events do
				local p = status_events[i]
				if type(p) == 'table' and p.state == 'running' then return true end
			end
			return false
		end, { timeout = 0.75, interval = 0.01 })
		if not saw_recovered then diag:fail('expected recovery to running after retry') end

		local writes = {}
		for i = 1, #fake_hal.calls do
			local c = fake_hal.calls[i]
			if c.method == 'write_state' then writes[#writes + 1] = c end
		end
		assert(#writes >= 2, 'expected at least two write_state attempts')

		local blob1 = decode_json(writes[1].req.data)
		local blob2 = decode_json(writes[2].req.data)
		assert(blob1.net.rev == 1)
		assert(blob2.net.rev == 1)
		assert(blob1.net.data.answer == 42)
		assert(blob2.net.data.answer == 42)
	end, { timeout = 1.5 })
end

return T
