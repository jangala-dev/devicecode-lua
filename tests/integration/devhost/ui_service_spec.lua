local busmod = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe = require 'tests.support.bus_probe'
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
		assert(ok, tostring(err))
		assert(probe.wait_until(function() return captured.app ~= nil end, { timeout = 0.5, interval = 0.01 }))

		local session, lerr = captured.app.login('admin', 'pw')
		assert(lerr == nil)
		local sid = session.session_id
		assert(type(sid) == 'string' and sid ~= '')

		local exact = assert(captured.app.model_exact(sid, { 'cfg', 'net' }))
		assert(exact.payload.rev == 2)
		assert(exact.payload.data.answer == 42)

		local snap = assert(captured.app.model_snapshot(sid, { 'svc', '#' }))
		assert(type(snap.entries) == 'table' and #snap.entries >= 2)

		local cfg = assert(captured.app.config_get(sid, 'net'))
		assert(cfg.rev == 2)
		assert(cfg.data.answer == 42)

		local svcs = assert(captured.app.services_snapshot(sid))
		assert(svcs.announce.alpha.role == 'alpha')
		assert(svcs.status.alpha.state == 'running')

		local fabric = assert(captured.app.fabric_status(sid))
		assert(fabric.main.kind == 'fabric.summary')
		assert(fabric.links.wan0.session.status.ready == true)

		local link = assert(captured.app.fabric_link_status(sid, 'wan0'))
		assert(link.session.status.ready == true)
		assert(link.bridge.status.connected == true)
		assert(link.transfer.status.idle == true)

		local caps = assert(captured.app.capability_snapshot(sid))
		assert(type(caps.capabilities['cap/fs/config/meta']) == 'table')
		assert(type(caps.devices['dev/modem/m1/meta']) == 'table')

		local cfgset = assert(captured.app.config_set(sid, 'net', { schema = 'devicecode.net/1', next = 99 }))
		assert(cfgset.ok == true)
		assert(#config_calls == 1)
		assert(config_calls[1].data.next == 99)

		local reply = assert(captured.app.call(sid, { 'rpc', 'svc', 'echo' }, { msg = 'hello' }, 0.25))
		assert(reply.echoed.msg == 'hello')
		assert(reply.via == 'echo')
		assert(#rpc_calls == 1)

		local watch = assert(captured.app.watch_open(sid, { 'cfg', '#' }, { queue_len = 16 }))
		local ev1 = select(1, watch:recv())
		assert(ev1.op == 'retain' and ev1.phase == 'replay')
		local ev2 = select(1, watch:recv())
		assert(ev2.op == 'replay_done')
		seed:retain({ 'cfg', 'wifi' }, { enabled = true })
		local ev3 = select(1, watch:recv())
		assert(ev3.op == 'retain' and ev3.phase == 'live')
		assert(ev3.topic[2] == 'wifi')
		assert(ev3.payload.enabled == true)
		watch:close('done')

		assert(#connect_calls >= 2)
		local saw_cfg, saw_call = false, false
		for i = 1, #connect_calls do
			local extra = connect_calls[i].origin_extra
			if type(extra) == 'table' and type(extra.ui) == 'table' then
				if extra.ui.op == 'config_set' then saw_cfg = true end
				if extra.ui.op == 'call' then saw_call = true end
			end
		end
		assert(saw_cfg == true)
		assert(saw_call == true)
	end, { timeout = 3.0 })
end

return T
