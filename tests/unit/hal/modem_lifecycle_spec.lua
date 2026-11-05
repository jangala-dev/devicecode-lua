local modem_driver = require 'services.hal.drivers.modem'
local runfibers = require 'tests.support.run_fibers'

local tests = {}

local function eq(actual, expected)
	assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

local function ok(value, err)
	assert(value, err)
end

local function lifecycle_logger()
	return {
		debug = function() end,
		trace = function() end,
		warn = function() end,
		error = function(_, entry)
			-- Fail promptly if the busy loop returns; a fiber timeout cannot
			-- interrupt a loop that never yields.
			assert(entry.what ~= 'state_monitor_error', 'lifecycle retried a missing state monitor')
		end,
	}
end

function tests.test_lifecycle_exits_when_state_monitor_disappears_after_initial_state()
	local op = require 'fibers.op'
	local channel = require 'fibers.channel'
	local Backend = require('services.hal.backends.modem.providers.linux_mm.impl')._test.ModemBackend

	runfibers.run(function()
		local driver = assert(modem_driver.new('test-modem', lifecycle_logger()))
		local backend = setmetatable({
			wait_for_sim_present_op = function() return op.never() end,
		}, Backend)
		backend.state_monitor = {
			stream = {
				read_line_op = function()
					backend.state_monitor = nil
					return op.always("modem: Initial state, 'registered'")
				end,
			},
		}
		driver.backend = backend
		driver.imei = 'test-imei'
		driver.cap_emit_ch = channel.new(4)

		driver:modem_lifecycle_monitor()

		local emitted = driver.cap_emit_ch:get()
		eq(emitted.key, 'card')
		eq(emitted.data.to, 'registered')
		eq(driver.scope:status(), 'running')
	end)
end

function tests.test_stop_cancels_workers_before_backend_shutdown_and_joins_them()
	local fibers = require 'fibers'
	local op = require 'fibers.op'
	local cond = require 'fibers.cond'

	runfibers.run(function()
		local driver = assert(modem_driver.new('test-modem', lifecycle_logger()))
		local started = cond.new()
		local worker_exited = false
		assert(driver.scope:spawn(function(s)
			s:finally(function() worker_exited = true end)
			started:signal()
			fibers.perform(op.never())
		end))
		started:wait()

		local shutdown_called = false
		driver.backend = {
			shutdown_op = function()
				return op.guard(function()
					eq(driver.scope:status(), 'cancelled')
					shutdown_called = true
					return op.always(true, '')
				end)
			end,
		}

		local stopped, err = driver:stop()
		ok(stopped, err)
		eq(err, '')
		eq(shutdown_called, true)
		eq(worker_exited, true)
	end)
end

return tests
