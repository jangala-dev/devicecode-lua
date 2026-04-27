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

		local st = probe.wait_service_running(conn, 'fabric', { timeout = 1.0, describe = function() return diag:render() end })
		local meta = probe.wait_retained_payload(conn, { 'svc', 'fabric', 'meta' }, { timeout = 1.0, predicate = function(payload) return type(payload) == 'table' and payload.role == 'fabric' end })

		assert(type(st) == 'table')
		assert(type(meta) == 'table')
		assert(st.state == 'running')
		assert(st.ready == true)
		assert(st.desired == 0)
		assert(st.live == 0)

		local summary = probe.wait_fabric_summary(conn, function(payload) return type(payload.links) == 'table' end, { timeout = 0.25 })
		assert(summary.kind == 'fabric.summary')
		assert(summary.component == 'summary')
		assert(type(summary.status) == 'table')
		assert(summary.status.desired == 0)
		assert(summary.status.live == 0)
		assert(type(summary.links) == 'table')

		local tm = probe.wait_transfer_manager_status(conn, function(payload) return payload.live_links == 0 and payload.desired_links == 0 end, { timeout = 0.25 })
		assert(type(tm) == 'table')

		local r1, e1 = conn:call({ 'cap', 'transfer-manager', 'main', 'rpc', 'send-blob' }, { op = 'status', link_id = 'missing' }, { timeout = 0.25 })
		assert(r1 == nil)
		assert(tostring(e1):match('no_such_link'))

		local r2, e2 = conn:call({ 'cap', 'transfer-manager', 'main', 'rpc', 'send-blob' }, { op = 'abort', link_id = 'missing' }, { timeout = 0.25 })
		assert(r2 == nil)
		assert(tostring(e2):match('no_such_link'))
	end, { timeout = 2.0 })
end

return T
