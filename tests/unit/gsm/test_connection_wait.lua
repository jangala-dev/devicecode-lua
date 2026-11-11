local gsm = require 'services.gsm'
local channel = require 'fibers.channel'
local run_virtual_fibers = require 'tests.support.run_virtual_fibers'
local time_harness = require 'tests.support.time_harness'

local tests = {}

function tests.test_connecting_state_has_a_bounded_settle_wait()
	local source_path = assert(debug.getinfo(gsm._test.wait_for_connection, 'S').source):gsub('^@', '')
	local source_file = assert(io.open(source_path, 'r'))
	local source = source_file:read('*a')
	source_file:close()
	local body = assert(source:match(
		'local function wait_for_connection.-\nend\n\n%-%-%-@class GsmModem'))
	local phase_two = assert(body:match('%-%- Phase 2:(.*)'))
	assert(not phase_two:find('state_sub:recv()', 1, true),
		'phase two uses an unbounded synchronous state receive')
	assert(phase_two:find('sleep.sleep_op', 1, true),
		'phase two has no settle deadline')
end

function tests.test_connecting_state_settles_at_one_absolute_deadline()
	run_virtual_fibers.run(function(scope, clock)
		local states = channel.new(4)
		local result, timeout_log
		local state_sub = { recv_op = function() return states:get_op() end }
		assert(scope:spawn(function()
			result = { gsm._test.wait_for_connection('primary', state_sub, function(level, payload)
				if payload.what == 'connection_settle_timeout' then
					timeout_log = { level = level, payload = payload }
				end
			end) }
		end))

		states:put({ payload = { to = 'connecting' } })
		time_harness.flush_ticks(10)
		assert(result == nil, 'connecting must initially wait for a terminal state')

		clock:advance(2)
		time_harness.flush_ticks(10)
		states:put({ payload = { to = 'connecting' } })
		time_harness.flush_ticks(10)
		clock:advance(1.1)
		time_harness.flush_ticks(20)

		assert(result and result[1] == true and result[2] == '')
		assert(timeout_log and timeout_log.level == 'warn')
		assert(timeout_log.payload.modem == 'primary')
	end)
end

return tests
