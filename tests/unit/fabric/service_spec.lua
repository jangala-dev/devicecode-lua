local busmod       = require 'bus'

local runfibers    = require 'tests.support.run_fibers'
local probe        = require 'tests.support.bus_probe'
local fake_hal_mod = require 'tests.support.fake_hal'

local fabric       = require 'services.fabric'

local T = {}

function T.fabric_service_announces_and_applies_empty_config()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect()

		local fake_hal = fake_hal_mod.new({
			backend = 'fakehal',
			caps = {},
			scripted = {},
		})
		fake_hal:start(bus:connect(), { name = 'hal' })

		conn:retain({ 'cfg', 'fabric' }, {
			schema = 'devicecode.fabric/1',
			links = {},
		})

		local ok_spawn, err = scope:spawn(function()
			fabric.start(bus:connect(), {
				name = 'fabric',
				env = 'dev',
				connect = function(principal)
					return bus:connect({ principal = principal })
				end,
			})
		end)
		assert(ok_spawn, tostring(err))

		local ann = probe.wait_payload(conn, { 'svc', 'fabric', 'announce' }, { timeout = 1.0 })
		assert(type(ann) == 'table')
		assert(ann.role == 'fabric')
		assert(type(ann.caps) == 'table')
		assert(ann.caps.pub_proxy == true)
		assert(ann.caps.firmware_push == true)

		local state = probe.wait_payload(conn, { 'state', 'fabric', 'main' }, { timeout = 1.0 })
		assert(type(state) == 'table')
		assert(state.status == 'running')
		assert(state.links == 0)
		assert(state.gen == 1)
	end, { timeout = 2.0 })
end

return T
