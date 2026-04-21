local busmod = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe = require 'tests.support.bus_probe'
local test_diag = require 'tests.support.test_diag'
local ui_service = require 'services.ui.service'
local ui_fakes = require 'tests.support.ui_fakes'

local T = {}

function T.ui_service_end_to_end_app_operations_over_bus_and_model()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local seed = bus:connect()
		ui_fakes.seed_ui_state(seed)

		local config_calls = {}
		ui_fakes.start_endpoint(scope, bus:connect(), { 'config', 'net', 'set' }, function(req)
			config_calls[#config_calls + 1] = req.payload
			req:reply({ ok = true, rev = 3 })
		end, { queue_len = 8 })

		local rpc_calls = {}
		ui_fakes.start_endpoint(scope, bus:connect(), { 'rpc', 'svc', 'echo' }, function(req)
			rpc_calls[#rpc_calls + 1] = req.payload
			req:reply({ echoed = req.payload, via = 'echo' })
		end, { queue_len = 8 })

		local connect, connect_calls = ui_fakes.connect_factory(bus)
		local diag = test_diag.start_profile(scope, bus, 'ui_stack', {
			conn = bus:connect(),
			max_records = 320,
			ui = {
				services_fn = function()
					return {
						announce = test_diag.retained_fn(bus:connect(), { 'svc', 'alpha', 'announce' })(),
						status = test_diag.retained_fn(bus:connect(), { 'svc', 'alpha', 'status' })(),
					}
				end,
			},
		})
		test_diag.add_calls(diag, 'config_calls', config_calls)
		test_diag.add_calls(diag, 'rpc_calls', rpc_calls)
		test_diag.add_calls(diag, 'connect_calls', connect_calls)
		local captured = {}
		local ok, err = scope:spawn(function()
			ui_service.start(bus:connect(), {
				name = 'ui',
				env = 'dev',
				connect = connect,
				verify_login = function(username, password)
					if username ~= 'admin' or password ~= 'pw' then return nil, 'invalid credentials' end
					return ui_fakes.principal('admin')
				end,
				run_http = function(_, app, http_opts)
					captured.app = app
					captured.ws_opts = http_opts.ws_opts
					while true do require('fibers.sleep').sleep(3600) end
				end,
				model_ready_timeout_s = 0.5,
			})
		end)
		if not ok then diag:fail('failed to spawn ui service: ' .. tostring(err)) end
		if not probe.wait_until(function() return captured.app ~= nil end, { timeout = 0.5, interval = 0.01 }) then
			diag:fail('expected ui app to be captured by fake http runner')
		end

		local session, lerr = captured.app.login('admin', 'pw')
		if lerr ~= nil or type(session) ~= 'table' or type(session.session_id) ~= 'string' or session.session_id == '' then
			diag:fail('expected successful ui login')
		end
		local sid = session.session_id

		local exact = captured.app.model_exact(sid, { 'cfg', 'net' })
		if type(exact) ~= 'table' or type(exact.payload) ~= 'table' or exact.payload.rev ~= 2 or exact.payload.data.answer ~= 42 then
			diag:fail('expected exact cfg/net payload from ui model')
		end

		local snap = captured.app.model_snapshot(sid, { 'svc', '#' })
		if type(snap) ~= 'table' or type(snap.entries) ~= 'table' or #snap.entries < 2 then
			diag:fail('expected non-trivial service snapshot from ui model')
		end

		local cfg = captured.app.config_get(sid, 'net')
		if type(cfg) ~= 'table' or cfg.rev ~= 2 or cfg.data.answer ~= 42 then
			diag:fail('expected config_get(net) to return retained config state')
		end

		local svcs = captured.app.services_snapshot(sid)
		if type(svcs) ~= 'table' or svcs.announce.alpha.role ~= 'alpha' or svcs.status.alpha.state ~= 'running' then
			diag:fail('expected services snapshot to contain seeded announce/status state')
		end

		local fabric = captured.app.fabric_status(sid)
		if type(fabric) ~= 'table' or fabric.main.kind ~= 'fabric.summary' or fabric.links.wan0.session.status.ready ~= true then
			diag:fail('expected fabric summary to contain ready wan0 link')
		end

		local link = captured.app.fabric_link_status(sid, 'wan0')
		if type(link) ~= 'table' or link.session.status.ready ~= true or link.bridge.status.connected ~= true or link.transfer.status.idle ~= true then
			diag:fail('expected fabric_link_status(wan0) to show ready/connected/idle')
		end

		local caps = captured.app.capability_snapshot(sid)
		if type(caps) ~= 'table' or type(caps.capabilities['cap/fs/config/meta']) ~= 'table' or type(caps.devices['dev/modem/m1/meta']) ~= 'table' then
			diag:fail('expected capability snapshot to contain seeded caps/devices')
		end

		local cfgset = captured.app.config_set(sid, 'net', { schema = 'devicecode.net/1', next = 99 })
		if type(cfgset) ~= 'table' or cfgset.ok ~= true or #config_calls ~= 1 or config_calls[1].data.next ~= 99 then
			diag:fail('expected config_set(net) to call endpoint and return ok')
		end

		local reply = captured.app.call(sid, { 'rpc', 'svc', 'echo' }, { msg = 'hello' }, 0.25)
		if type(reply) ~= 'table' or reply.echoed.msg ~= 'hello' or reply.via ~= 'echo' or #rpc_calls ~= 1 then
			diag:fail('expected ui rpc call to reach fake echo endpoint')
		end

		local watch = captured.app.watch_open(sid, { 'cfg', '#' }, { queue_len = 16 })
		if type(watch) ~= 'table' then diag:fail('expected watch_open to return a watcher') end
		local ev1 = select(1, watch:recv())
		local ev2 = select(1, watch:recv())
		if not (type(ev1) == 'table' and ev1.op == 'retain' and ev1.phase == 'replay' and type(ev2) == 'table' and ev2.op == 'replay_done') then
			diag:fail('expected cfg watch replay to emit retain then replay_done')
		end
		seed:retain({ 'cfg', 'wifi' }, { enabled = true })
		local ev3 = select(1, watch:recv())
		if not (type(ev3) == 'table' and ev3.op == 'retain' and ev3.phase == 'live' and ev3.topic[2] == 'wifi' and ev3.payload.enabled == true) then
			diag:fail('expected cfg watch to receive live wifi retain event')
		end
		watch:close('done')

		if #connect_calls < 2 then diag:fail('expected at least two ui-originated bus connections') end
		local saw_cfg, saw_call = false, false
		for i = 1, #connect_calls do
			local extra = connect_calls[i].origin_extra
			if type(extra) == 'table' and type(extra.ui) == 'table' then
				if extra.ui.op == 'config_set' then saw_cfg = true end
				if extra.ui.op == 'call' then saw_call = true end
			end
		end
		if not (saw_cfg == true and saw_call == true) then
			diag:fail('expected connect_factory origin_extra to record config_set and call operations')
		end
	end, { timeout = 3.0 })
end

return T
