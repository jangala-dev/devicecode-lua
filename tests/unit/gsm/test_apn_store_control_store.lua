local fibers = require 'fibers'
local op = require 'fibers.op'
local runfibers = require 'tests.support.run_fibers'
local store_mod = require 'services.gsm.apn_store_control_store'

local tests = {}

local function fake_conn()
	local data = {}
	return {
		data = data,
		call_op = function(_, topic, payload)
			local method = topic[5]
			if method == 'get' then
				if data[payload.key] == nil then return op.always({ ok = false, reason = 'not found' }, nil) end
				return op.always({ ok = true, reason = data[payload.key] }, nil)
			elseif method == 'put' then
				data[payload.key] = payload.data
				return op.always({ ok = true, reason = nil }, nil)
			end
			return op.always({ ok = false, reason = 'bad_method' }, nil)
		end,
	}
end

function tests.test_save_accepts_void_successful_control_store_put()
	runfibers.run(function()
		local conn = fake_conn()
		local store = store_mod.new(conn)

		local saved, save_err = fibers.perform(store:save_op({
			{ carrier = 'O2 - UK', mcc = '234', mnc = '10', apn = 'payandgo.o2.co.uk' },
		}))
		assert(saved ~= nil, tostring(save_err))
		assert(saved[1].apn == 'payandgo.o2.co.uk')
		assert(conn.data['custom-apns-v1'] ~= nil)

		local loaded, load_err = fibers.perform(store:load_op())
		assert(loaded ~= nil, tostring(load_err))
		assert(loaded[1].carrier == 'O2 - UK')
		assert(loaded[1].mcc == '234')
		assert(loaded[1].mnc == '10')
		assert(loaded[1].apn == 'payandgo.o2.co.uk')
	end)
end

return tests
