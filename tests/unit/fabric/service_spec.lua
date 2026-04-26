local busmod    = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'
local test_diag = require 'tests.support.test_diag'
local fabric    = require 'services.fabric'
local safe      = require 'coxpcall'

local T = {}

function T.fabric_service_applies_empty_config_and_exposes_transfer_endpoint()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local diag = test_diag.for_stack(scope, bus, { fabric = true, max_records = 240 })
		test_diag.add_subsystem(diag, 'fabric', {
			service_fn = test_diag.retained_fn(conn, { 'svc', 'fabric', 'status' }),
			summary_fn = test_diag.retained_fn(conn, { 'state', 'fabric' }),
		})

		conn:retain({ 'cfg', 'fabric' }, { links = {} })

		local ok_spawn, err = scope:spawn(function()
			fabric.start(bus:connect(), { name = 'fabric', env = 'dev' })
		end)
		if not ok_spawn then diag:fail('failed to spawn fabric service: ' .. tostring(err)) end

		local st
		assert(probe.wait_until(function()
			local ok, payload = safe.pcall(function()
				return probe.wait_payload(conn, { 'svc', 'fabric', 'status' }, { timeout = 0.05 })
			end)
			if ok and type(payload) == 'table' and payload.state == 'running' and payload.ready == true then
				st = payload
				return true
			end
			return false
		end, { timeout = 1.0, interval = 0.01 }))
		assert(probe.wait_until(function()
			local ok, payload = safe.pcall(function()
				return probe.wait_payload(conn, { 'svc', 'fabric', 'announce' }, { timeout = 0.05 })
			end)
			return ok and type(payload) == 'table' and payload.role == 'fabric'
		end, { timeout = 1.0, interval = 0.01 }))

		assert(type(st) == 'table')
		assert(st.state == 'running')
		assert(st.ready == true)
		assert(st.desired == 0)
		assert(st.live == 0)

		local summary = probe.wait_payload(conn, { 'state', 'fabric' }, { timeout = 0.25 })
		assert(summary.kind == 'fabric.summary')
		assert(summary.component == 'summary')
		assert(type(summary.status) == 'table')
		assert(summary.status.desired == 0)
		assert(summary.status.live == 0)
		assert(type(summary.links) == 'table')

		local r1, e1 = conn:call({ 'cap', 'transfer-manager', 'main', 'rpc', 'send-blob' }, { op = 'status', link_id = 'missing' }, { timeout = 0.25 })
		assert(r1 == nil)
		assert(tostring(e1):match('no_such_link'))

		local r2, e2 = conn:call({ 'cap', 'transfer-manager', 'main', 'rpc', 'send-blob' }, { op = 'abort', link_id = 'missing' }, { timeout = 0.25 })
		assert(r2 == nil)
		assert(tostring(e2):match('no_such_link'))
	end, { timeout = 2.0 })
end

return T
