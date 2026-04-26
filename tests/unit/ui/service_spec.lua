local busmod = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe = require 'tests.support.bus_probe'
local test_diag = require 'tests.support.test_diag'
local ui_service = require 'services.ui.service'
local ui_fakes = require 'tests.support.ui_fakes'
local safe = require 'coxpcall'

local T = {}

function T.ui_service_bootstraps_and_tracks_sessions_and_clients()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local seed = bus:connect()
		ui_fakes.seed_ui_state(seed)
		local connect, calls = ui_fakes.connect_factory(bus)
		local captured = {}
		local diag = test_diag.for_stack(scope, bus, { ui = true, config = true, max_records = 240 })
		test_diag.add_calls(diag, 'connect_calls', calls)
		test_diag.add_subsystem(diag, 'ui', {
			service_fn = test_diag.retained_fn(bus:connect(), { 'svc', 'ui', 'status' }),
			announce_fn = test_diag.retained_fn(bus:connect(), { 'svc', 'ui', 'announce' }),
			main_fn = test_diag.retained_fn(bus:connect(), { 'state', 'ui', 'summary' }),
			config_net_fn = test_diag.retained_fn(bus:connect(), { 'cfg', 'net' }),
			fabric_fn = test_diag.retained_fn(bus:connect(), { 'state', 'fabric' }),
		})

		local ok, err = scope:spawn(function()
			ui_service.start(bus:connect(), {
				name = 'ui',
				env = 'dev',
				connect = connect,
				verify_login = function(username, password)
					assert(username == 'alice')
					assert(password == 'pw')
					return ui_fakes.principal('alice')
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

		assert(probe.wait_until(function() return captured.app ~= nil and captured.ws_opts ~= nil end, { timeout = 0.5, interval = 0.01 }))
		assert(probe.wait_until(function()
			local okp, payload = safe.pcall(function()
				return probe.wait_payload(bus:connect(), { 'svc', 'ui', 'announce' }, { timeout = 0.02 })
			end)
			return okp and type(payload) == 'table' and payload.role == 'ui'
		end, { timeout = 0.75, interval = 0.01 }))
		assert(probe.wait_until(function()
			local okp, payload = safe.pcall(function()
				return probe.wait_payload(bus:connect(), { 'svc', 'ui', 'status' }, { timeout = 0.02 })
			end)
			return okp and type(payload) == 'table' and payload.state == 'running' and payload.ready == true and payload.model_ready == true
		end, { timeout = 0.75, interval = 0.01 }))
		assert(probe.wait_until(function()
			local okp, payload = safe.pcall(function()
				return probe.wait_payload(bus:connect(), { 'state', 'ui', 'summary' }, { timeout = 0.02 })
			end)
			return okp and type(payload) == 'table' and payload.status == 'running' and payload.model_ready == true
		end, { timeout = 0.75, interval = 0.01 }))

		local sess, serr = captured.app.login('alice', 'pw')
		assert(serr == nil)
		assert(type(sess.session_id) == 'string')
		assert(probe.wait_until(function()
			local payload = probe.wait_payload(bus:connect(), { 'state', 'ui', 'summary' }, { timeout = 0.02 })
			return payload.sessions == 1
		end, { timeout = 0.5, interval = 0.01 }))

		captured.ws_opts.on_opened()
		assert(probe.wait_until(function()
			local payload = probe.wait_payload(bus:connect(), { 'state', 'ui', 'summary' }, { timeout = 0.02 })
			return payload.clients == 1
		end, { timeout = 0.5, interval = 0.01 }))
		captured.ws_opts.on_closed()
		assert(probe.wait_until(function()
			local payload = probe.wait_payload(bus:connect(), { 'state', 'ui', 'summary' }, { timeout = 0.02 })
			return payload.clients == 0
		end, { timeout = 0.5, interval = 0.01 }))

		local out, lerr = captured.app.logout(sess.session_id)
		assert(lerr == nil)
		assert(out.ok == true)
		assert(probe.wait_until(function()
			local payload = probe.wait_payload(bus:connect(), { 'state', 'ui', 'summary' }, { timeout = 0.02 })
			return payload.sessions == 0
		end, { timeout = 0.5, interval = 0.01 }))
		assert(#calls == 0)
	end, { timeout = 2.0 })
end

return T
