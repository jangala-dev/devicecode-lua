local busmod     = require 'bus'
local duplex     = require 'tests.support.duplex_stream'
local probe      = require 'tests.support.bus_probe'
local runfibers  = require 'tests.support.run_fibers'
local safe       = require 'coxpcall'
local test_diag  = require 'tests.support.test_diag'

local fabric     = require 'services.fabric'

local T = {}

function T.fabric_services_reach_ready_on_separate_buses_over_duplex_streams()
	runfibers.run(function(scope)
		local bus_a = busmod.new()
		local bus_b = busmod.new()
		local obs_a = bus_a:connect()
		local obs_b = bus_b:connect()
		local diag_a = test_diag.for_stack(scope, bus_a, { fabric = true, obs = true, max_records = 240 })
		local diag_b = test_diag.for_stack(scope, bus_b, { fabric = true, obs = true, max_records = 240 })
		test_diag.add_subsystem(diag_a, 'fabric', {
			service_fn = test_diag.retained_fn(bus_a:connect(), { 'svc', 'fabric', 'status' }),
			summary_fn = test_diag.retained_fn(bus_a:connect(), { 'state', 'fabric' }),
			session_fn = test_diag.retained_fn(bus_a:connect(), { 'state', 'fabric', 'link', 'ab', 'session' }),
			bridge_fn = test_diag.retained_fn(bus_a:connect(), { 'state', 'fabric', 'link', 'ab', 'bridge' }),
			transfer_fn = test_diag.retained_fn(bus_a:connect(), { 'state', 'fabric', 'link', 'ab', 'transfer' }),
		})
		test_diag.add_subsystem(diag_b, 'fabric', {
			service_fn = test_diag.retained_fn(bus_b:connect(), { 'svc', 'fabric', 'status' }),
			summary_fn = test_diag.retained_fn(bus_b:connect(), { 'state', 'fabric' }),
			session_fn = test_diag.retained_fn(bus_b:connect(), { 'state', 'fabric', 'link', 'ba', 'session' }),
			bridge_fn = test_diag.retained_fn(bus_b:connect(), { 'state', 'fabric', 'link', 'ba', 'bridge' }),
			transfer_fn = test_diag.retained_fn(bus_b:connect(), { 'state', 'fabric', 'link', 'ba', 'transfer' }),
		})

		local a_stream, b_stream = duplex.new_pair()

		obs_a:retain({ 'cfg', 'fabric' }, {
			links = {
				wan0 = {
					id = 'wan0',
					node_id = 'node-a',
					transport = { open = function() return a_stream end },
					export_publish_rules = {
						{ ['local'] = { 'local' }, ['remote'] = { 'remote' } },
					},
					import_rules = {
						{ ['local'] = { 'seen' }, ['remote'] = { 'remote' } },
					},
					outbound_call_rules = {},
					inbound_call_rules = {},
				},
			},
		})

		obs_b:retain({ 'cfg', 'fabric' }, {
			links = {
				wan0 = {
					id = 'wan0',
					node_id = 'node-b',
					transport = { open = function() return b_stream end },
					export_publish_rules = {
						{ ['local'] = { 'local' }, ['remote'] = { 'remote' } },
					},
					import_rules = {
						{ ['local'] = { 'seen' }, ['remote'] = { 'remote' } },
					},
					outbound_call_rules = {},
					inbound_call_rules = {},
				},
			},
		})

		local ok1, err1 = scope:spawn(function()
			fabric.start(bus_a:connect(), { name = 'fabric', env = 'dev' })
		end)
		assert(ok1, tostring(err1))

		local ok2, err2 = scope:spawn(function()
			fabric.start(bus_b:connect(), { name = 'fabric', env = 'dev' })
		end)
		assert(ok2, tostring(err2))

		probe.wait_fabric_ready(obs_a, 'wan0', { timeout = 2.0, describe = function() return 'expected fabric side A to reach ready' end })
		probe.wait_fabric_ready(obs_b, 'wan0', { timeout = 2.0, describe = function() return 'expected fabric side B to reach ready' end })

		obs_a:publish({ 'local', 'wifi' }, { up = true })
		local ok_seen, seen = safe.pcall(function() return probe.wait_payload(obs_b, { 'seen', 'wifi' }, { timeout = 1.0 }) end)
		if not ok_seen or type(seen) ~= 'table' or seen.up ~= true then
			diag_b:fail('expected published wifi state to be imported on side B')
		end
	end, { timeout = 3.0 })
end

return T
