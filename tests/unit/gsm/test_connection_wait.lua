local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local pulse = require 'fibers.pulse'
local runfibers = require 'tests.support.run_fibers'
local gsm = require 'services.gsm'

local tests = {}

function tests.test_connecting_state_has_a_bounded_settle_wait()
	runfibers.run(function(scope)
		local first = true
		local result = {}
		local done = pulse.new()
		local done_version = done:version()
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

		assert(scope:spawn(function()
			result.ok, result.err = gsm._test.wait_for_connection('primary', state_sub, nil, 0.02)
			done:signal()
		end))

		local completed = fibers.perform(op.boolean_choice(
			done:changed_op(done_version):wrap(function() return true end),
			sleep.sleep_op(0.1):wrap(function() return false end)
		))
		assert(completed, 'connection settle wait did not respect its timeout')
		assert(result.ok == false, 'a permanently connecting modem must not settle successfully')
		assert(tostring(result.err):find('timeout', 1, true), tostring(result.err))
	end, { timeout = 0.5 })
end

return tests
