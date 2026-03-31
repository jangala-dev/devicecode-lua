-- tests/config_state_spec.lua

local state = require 'services.config.state'

local T = {}

local function fake_conn()
	local retained = {}
	return {
		retained = retained,
		retain = function(_, topic, payload)
			retained[#retained + 1] = { topic = topic, payload = payload }
			return true
		end,
	}
end

function T.set_service_increments_revision_and_copies_input()
	local conn = fake_conn()
	local current = {}

	local payload = {
		data = {
			schema = 'devicecode.test/1',
			x = { y = 1 },
		},
	}

	local ok, err = state.set_service(current, conn, nil, nil, 'net', payload, nil)
	assert(ok == true, tostring(err))
	assert(current.net.rev == 1)
	assert(current.net.data ~= payload.data)
	assert(current.net.data.x ~= payload.data.x)

	payload.data.x.y = 99
	assert(current.net.data.x.y == 1)

	local ok2, err2 = state.set_service(current, conn, nil, nil, 'net', payload, nil)
	assert(ok2 == true, tostring(err2))
	assert(current.net.rev == 2)
end

function T.publish_all_retained_publishes_copies()
	local conn = fake_conn()
	local current = {
		net = {
			rev = 3,
			data = {
				schema = 'devicecode.test/1',
				x = { y = 1 },
			},
		},
	}

	state.publish_all_retained(conn, nil, current)
	assert(#conn.retained == 1)
	assert(conn.retained[1].payload ~= current.net)
	assert(conn.retained[1].payload.data ~= current.net.data)
end

return T
