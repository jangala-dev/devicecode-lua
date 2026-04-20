local busmod     = require 'bus'
local duplex     = require 'tests.support.duplex_stream'
local probe      = require 'tests.support.bus_probe'
local runfibers  = require 'tests.support.run_fibers'
local safe       = require 'coxpcall'
local fabric     = require 'services.fabric'

local T = {}

local function wait_ready(conn, topic, timeout)
	return probe.wait_until(function()
		local ok, payload = safe.pcall(function()
			return probe.wait_payload(conn, topic, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table'
			and type(payload.status) == 'table'
			and payload.status.ready == true
	end, { timeout = timeout or 1.5, interval = 0.01 })
end

function T.fabric_service_reaches_ready_on_separate_buses_over_duplex_streams()
	runfibers.run(function(scope)
		local cm5_bus = busmod.new()
		local mcu_bus = busmod.new()

		local cm5_probe = cm5_bus:connect()
		local mcu_probe = mcu_bus:connect()

		local a_stream, b_stream = duplex.new_pair()

		cm5_bus:connect():retain({ 'cfg', 'fabric' }, {
			links = {
				['cm5-uart-mcu'] = {
					id = 'cm5-uart-mcu',
					node_id = 'cm5',
					member_class = 'mcu',
					link_class = 'member_uart',
					transport = { open = function() return a_stream end },
					import_rules = {},
					outbound_call_rules = {},
				},
			},
		})

		mcu_bus:connect():retain({ 'cfg', 'fabric' }, {
			links = {
				['mcu-uart-cm5'] = {
					id = 'mcu-uart-cm5',
					node_id = 'mcu',
					member_class = 'cm5',
					link_class = 'member_uart',
					transport = { open = function() return b_stream end },
					import_rules = {},
					outbound_call_rules = {},
				},
			},
		})

		local ok1, err1 = scope:spawn(function()
			fabric.start(cm5_bus:connect(), { name = 'fabric', env = 'dev' })
		end)
		assert(ok1, tostring(err1))

		local ok2, err2 = scope:spawn(function()
			fabric.start(mcu_bus:connect(), { name = 'fabric', env = 'dev' })
		end)
		assert(ok2, tostring(err2))

		assert(wait_ready(cm5_probe, { 'state', 'fabric', 'link', 'cm5-uart-mcu', 'session' }, 2.0) == true)
		assert(wait_ready(mcu_probe, { 'state', 'fabric', 'link', 'mcu-uart-cm5', 'session' }, 2.0) == true)
	end, { timeout = 3.0 })
end

return T
