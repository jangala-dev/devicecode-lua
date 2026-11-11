local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local runfibers = require 'tests.support.run_fibers'
local gsm = require 'services.gsm'

local tests = {}

function tests.test_connecting_state_has_a_bounded_settle_wait()
	runfibers.run(function()
		local first = true
		local state_sub = {
			recv_op = function()
				if first then
					first = false
					return op.always({ payload = { to = 'connecting' } })
				end
				return sleep.sleep_op(60)
			end,
			recv = function()
				fibers.perform(sleep.sleep_op(60))
			end,
		}

		local ok, err = gsm._test.wait_for_connection('primary', state_sub, nil, 0.02)
		assert(ok == false, 'a permanently connecting modem must not settle successfully')
		assert(tostring(err):find('timeout', 1, true), tostring(err))
	end, { timeout = 0.15 })
end

return tests
