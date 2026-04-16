local busmod    = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'
local fabric    = require 'services.fabric'
local safe      = require 'coxpcall'

local T = {}

function T.fabric_service_applies_empty_config_and_exposes_transfer_endpoint()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect()

		conn:retain({ 'cfg', 'fabric' }, { links = {} })

		local ok_spawn, err = scope:spawn(function()
			fabric.start(bus:connect(), { name = 'fabric', env = 'dev' })
		end)
		assert(ok_spawn, tostring(err))

		local st
		assert(probe.wait_until(function()
			local ok, payload = safe.pcall(function()
				return probe.wait_payload(conn, { 'svc', 'fabric', 'status' }, { timeout = 0.05 })
			end)
			if ok and type(payload) == 'table' and payload.state == 'running' then
				st = payload
				return true
			end
			return false
		end, { timeout = 1.0, interval = 0.01 }))
		assert(type(st) == 'table')
		assert(st.state == 'running')
		assert(st.links == 0)

		local r1, e1 = conn:call({ 'cmd', 'fabric', 'transfer' }, { op = 'status', link_id = 'missing' }, { timeout = 0.25 })
		assert(r1 == nil)
		assert(tostring(e1):match('no_such_link'))

		local r2, e2 = conn:call({ 'cmd', 'fabric', 'transfer' }, { op = 'abort', link_id = 'missing' }, { timeout = 0.25 })
		assert(r2 == nil)
		assert(tostring(e2):match('no_such_link'))
	end, { timeout = 2.0 })
end

return T
