-- tests/unit/hal/radio_driver_spec.lua

local tests = {}

local function eq(a, b, msg)
	if a ~= b then
		error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
	end
end

function tests.test_stats_loop_stops_when_client_monitor_cannot_start()
	local channel = require 'fibers.channel'
	local runfibers = require 'tests.support.run_fibers'
	local radio = require 'services.hal.drivers.radio'

	runfibers.run(function ()
		local start_calls = 0
		local watch_calls = 0
		local errors = {}

		local backend = {
			start_client_monitor = function ()
				start_calls = start_calls + 1
				return false, 'failed to start iw event: iw not found'
			end,

			watch_clients_op = function ()
				watch_calls = watch_calls + 1
				error('watch_clients_op should not be called after monitor startup failure', 2)
			end,
		}

		local driver = setmetatable({
			id = 'radio0',
			cap_emit_ch = channel.new(4),
			iface_update_ch = channel.new(4),
			report_period_ch = channel.new(1),
			backend = backend,
			log = {
				error = function (_, row)
					errors[#errors + 1] = row
				end,
				debug = function () end,
			},
		}, radio.Driver)

		driver:stats_loop()

		eq(start_calls, 1, 'client monitor should only be started once')
		eq(watch_calls, 0, 'stats loop should not watch clients after monitor startup failure')
		eq(#errors, 1, 'startup failure should be logged once')
		eq(errors[1].what, 'radio_stats_loop_failed', 'failure log event')
		eq(errors[1].id, 'radio0', 'failure log id')
	end, { timeout = 0.1 })
end

function tests.test_stats_loop_stops_when_client_monitor_stream_closes()
	local channel = require 'fibers.channel'
	local op = require 'fibers.op'
	local runfibers = require 'tests.support.run_fibers'
	local radio = require 'services.hal.drivers.radio'

	runfibers.run(function ()
		local start_calls = 0
		local watch_calls = 0
		local stop_calls = 0
		local errors = {}

		local backend = {
			start_client_monitor = function ()
				start_calls = start_calls + 1
				return true, ''
			end,

			watch_clients_op = function ()
				watch_calls = watch_calls + 1
				return op.always(nil, 'iw event stream closed')
			end,

			stop_client_monitor_op = function ()
				stop_calls = stop_calls + 1
				return op.always(true, '')
			end,

			terminate = function () return true, nil end,
		}

		local driver = setmetatable({
			id = 'radio0',
			cap_emit_ch = channel.new(4),
			iface_update_ch = channel.new(4),
			report_period_ch = channel.new(1),
			backend = backend,
			log = {
				error = function (_, row)
					errors[#errors + 1] = row
				end,
				debug = function () end,
			},
		}, radio.Driver)

		driver:stats_loop()

		eq(start_calls, 1, 'client monitor should only be started once')
		eq(watch_calls, 1, 'closed monitor stream should only be watched once')
		eq(stop_calls, 1, 'started monitor should be stopped after stream failure')
		eq(#errors, 1, 'stream failure should be logged once')
		eq(errors[1].what, 'radio_stats_loop_failed', 'failure log event')
		eq(errors[1].err, 'iw event stream closed', 'failure log err')
	end, { timeout = 0.1 })
end

return tests
