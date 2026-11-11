local gsm = require 'services.gsm'

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

return tests
