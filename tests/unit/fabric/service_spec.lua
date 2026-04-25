local busmod    = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'
local test_diag = require 'tests.support.test_diag'
local fabric    = require 'services.fabric'
local safe      = require 'coxpcall'

local T = {}

local function wait_fabric_service_ready(conn, timeout)
	local status
	assert(probe.wait_until(function()
		local ok, payload = safe.pcall(function()
			return probe.wait_payload(conn, { 'svc', 'fabric', 'status' }, { timeout = 0.05 })
		end)
		if ok and type(payload) == 'table' and payload.state == 'running' and payload.ready == true then
			status = payload
			return true
		end
		return false
	end, { timeout = timeout or 1.0, interval = 0.01 }))
	return status
end

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

		local st = wait_fabric_service_ready(conn, 1.0)
		assert(type(st) == 'table')
		assert(st.state == 'running')
		assert(st.ready == true)
		assert(type(st.run_id) == 'string')
		assert(st.desired == 0)
		assert(st.live == 0)

		local ann = probe.wait_payload(conn, { 'svc', 'fabric', 'announce' }, { timeout = 0.25 })
		assert(type(ann) == 'table')
		assert(ann.role == 'fabric')
		assert(type(ann.caps) == 'table')
		assert(ann.caps.transfer_rpc == true)
		assert(type(ann.run_id) == 'string')
		assert(ann.run_id == st.run_id)

		local summary = probe.wait_payload(conn, { 'state', 'fabric' }, { timeout = 0.25 })
		assert(summary.kind == 'fabric.summary')
		assert(summary.component == 'summary')
		assert(type(summary.status) == 'table')
		assert(summary.status.desired == 0)
		assert(summary.status.live == 0)
		assert(type(summary.links) == 'table')

		local r1, e1 = conn:call({ 'cmd', 'fabric', 'transfer' }, { op = 'status', link_id = 'missing' }, { timeout = 0.25 })
		assert(r1 == nil)
		assert(tostring(e1):match('no_such_link'))

		local r2, e2 = conn:call({ 'cmd', 'fabric', 'transfer' }, { op = 'abort', link_id = 'missing' }, { timeout = 0.25 })
		assert(r2 == nil)
		assert(tostring(e2):match('no_such_link'))
	end, { timeout = 2.0 })
end

return T
