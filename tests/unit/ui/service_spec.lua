-- tests/unit/ui/service_spec.lua

local sleep      = require 'fibers.sleep'
local busmod     = require 'bus'

local runfibers  = require 'tests.support.run_fibers'
local probe      = require 'tests.support.bus_probe'

local ui_service = require 'services.ui'

local T = {}

local function start_ui(scope, bus, opts)
	opts = opts or {}

	local captured_api = nil

	local ok_spawn, err = scope:spawn(function()
		ui_service.start(bus:connect(), {
			name = 'ui',
			env  = 'dev',

			connect = function(principal)
				return bus:connect({ principal = principal })
			end,

			verify_login = opts.verify_login or function(username, password)
				if username == 'admin' and password == 'secret' then
					return {
						kind  = 'user',
						id    = 'admin',
						roles = { 'admin' },
					}, nil
				end
				return nil, 'invalid credentials'
			end,

			run_http = function(_, api, _)
				captured_api = api
				while true do
					sleep.sleep(1.0)
				end
			end,
		})
	end)
	assert(ok_spawn, tostring(err))

	local ready = probe.wait_until(function()
		return captured_api ~= nil
	end, { timeout = 0.5, interval = 0.01 })

	assert(ready == true, 'expected ui api to be captured')
	return captured_api
end

local function seed_retained(bus, topic, payload)
	local conn = bus:connect()
	conn:retain(topic, payload)
end

local function unretain(bus, topic)
	local conn = bus:connect()
	conn:unretain(topic)
end

local function spawn_fake_config_acceptor(scope, bus, service_name, calls)
	calls = calls or {}
	local ready = false

	local ok_spawn, err = scope:spawn(function()
		local conn = bus:connect()
		local sub = conn:subscribe({ 'config', service_name, 'set' }, {
			queue_len = 8,
			full      = 'reject_newest',
		})
		ready = true

		while true do
			local msg, _ = sub:recv()
			if not msg then return end

			calls[#calls + 1] = {
				topic   = msg.topic,
				payload = msg.payload,
				id      = msg.id,
			}

			if msg.reply_to ~= nil then
				conn:publish(msg.reply_to, { ok = true, persisted = false }, { id = msg.id })
			end
		end
	end)
	assert(ok_spawn, tostring(err))

	local ok = probe.wait_until(function() return ready == true end, { timeout = 0.5, interval = 0.01 })
	assert(ok == true, 'expected fake config acceptor to be ready')
	return calls
end

local function spawn_fake_rpc_endpoint(scope, bus, service_name, method_name, handler, calls)
	calls = calls or {}
	local ready = false

	local ok_spawn, err = scope:spawn(function()
		local conn = bus:connect()
		local ep = conn:bind({ 'rpc', service_name, method_name }, { queue_len = 8 })
		ready = true

		while true do
			local msg, _ = ep:recv()
			if not msg then return end

			calls[#calls + 1] = {
				topic   = msg.topic,
				payload = msg.payload,
				id      = msg.id,
			}

			local reply = handler and handler(msg.payload, msg) or { ok = true }
			if msg.reply_to ~= nil then
				local rok, rwhy = conn:publish_one(msg.reply_to, reply, { id = msg.id })
				assert(rok == true, tostring(rwhy))
			end
		end
	end)
	assert(ok_spawn, tostring(err))

	local ok = probe.wait_until(function() return ready == true end, { timeout = 0.5, interval = 0.01 })
	assert(ok == true, 'expected fake rpc endpoint to be ready')
	return calls
end

function T.ui_login_accepts_admin_and_emits_audit()
	runfibers.run(function(scope)
		local bus  = busmod.new()
		local conn = bus:connect()

		local api = assert(start_ui(scope, bus))
		local sub = conn:subscribe({ 'obs', 'audit', 'ui', 'login' }, {
			queue_len = 1,
			full      = 'reject_newest',
		})

		local out, err = api.login('admin', 'secret')
		assert(out ~= nil, tostring(err))
		assert(type(out.session_id) == 'string' and out.session_id ~= '')
		assert(out.user.id == 'admin')
		assert(out.user.roles[1] == 'admin')

		local msg, merr = sub:recv()
		assert(msg ~= nil, tostring(merr))
		assert(msg.payload.user == 'admin')
	end, { timeout = 1.0 })
end

function T.ui_login_rejects_bad_password()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local api = assert(start_ui(scope, bus))

		local out, err = api.login('admin', 'wrong')
		assert(out == nil)
		assert(tostring(err) == 'invalid credentials')
	end, { timeout = 1.0 })
end

function T.ui_get_session_and_logout_invalidates_session()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local api = assert(start_ui(scope, bus))

		local login, lerr = api.login('admin', 'secret')
		assert(login ~= nil, tostring(lerr))

		local sess, serr = api.get_session(login.session_id)
		assert(sess ~= nil, tostring(serr))
		assert(sess.user.id == 'admin')
		assert(sess.session_id == login.session_id)

		local ok, oerr = api.logout(login.session_id)
		assert(ok == true, tostring(oerr))

		local gone, gerr = api.get_session(login.session_id)
		assert(gone == nil)
		assert(tostring(gerr) == 'invalid or expired session')
	end, { timeout = 1.0 })
end

function T.ui_config_get_reads_retained_snapshot()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local api = assert(start_ui(scope, bus))

		seed_retained(bus, { 'cfg', 'net' }, {
			rev = 3,
			data = { schema = 'devicecode.net/2', answer = 42 },
		})

		local login = assert((api.login('admin', 'secret')))
		local out, err = api.config_get(login.session_id, 'net')
		assert(out ~= nil, tostring(err))
		assert(out.rev == 3)
		assert(out.data.answer == 42)
	end, { timeout = 1.0 })
end

function T.ui_service_status_reads_retained_status()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local api = assert(start_ui(scope, bus))

		seed_retained(bus, { 'svc', 'net', 'status' }, { state = 'running', ts = 123.0 })

		local login = assert((api.login('admin', 'secret')))
		local out, err = api.service_status(login.session_id, 'net')
		assert(out ~= nil, tostring(err))
		assert(out.state == 'running')
	end, { timeout = 1.0 })
end

function T.ui_config_set_round_trips_via_bus()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local calls = {}
		spawn_fake_config_acceptor(scope, bus, 'net', calls)
		local api = assert(start_ui(scope, bus))

		local login = assert((api.login('admin', 'secret')))
		local out, err = api.config_set(login.session_id, 'net', {
			schema = 'devicecode.net/1',
			answer = 42,
		})
		assert(out ~= nil, tostring(err))
		assert(out.ok == true)
		assert(out.persisted == false)

		assert(probe.wait_until(function() return #calls >= 1 end, { timeout = 0.5, interval = 0.01 }) == true)
		assert(calls[1].topic[1] == 'config')
		assert(calls[1].topic[2] == 'net')
		assert(calls[1].topic[3] == 'set')
		assert(calls[1].payload.data.answer == 42)
	end, { timeout = 1.0 })
end

function T.ui_rpc_call_round_trips_via_endpoint()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local calls = {}
		spawn_fake_rpc_endpoint(scope, bus, 'hal', 'dump', function(payload, msg)
			return {
				ok       = true,
				echo     = payload,
				method   = 'dump',
				reply_to = msg.reply_to ~= nil,
			}
		end, calls)

		local api = assert(start_ui(scope, bus))
		local login = assert((api.login('admin', 'secret')))
		local out, err = api.rpc_call(login.session_id, 'hal', 'dump', { packages = { 'network', 'firewall' } }, 0.5)

		assert(out ~= nil, tostring(err))
		assert(out.ok == true)
		assert(out.method == 'dump')
		assert(out.reply_to == true)
		assert(out.echo.packages[1] == 'network')
		assert(#calls == 1)
	end, { timeout = 1.0 })
end

function T.ui_fabric_status_and_link_status_read_retained_state()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local api = assert(start_ui(scope, bus))

		seed_retained(bus, { 'state', 'fabric', 'main' }, { status = 'running', gen = 2 })
		seed_retained(bus, { 'state', 'fabric', 'link', 'uart0' }, { status = 'ready', peer_id = 'peer-a' })
		seed_retained(bus, { 'state', 'fabric', 'link', 'uart0', 'transfer' }, { status = 'idle' })

		local login = assert((api.login('admin', 'secret')))
		local fabric, ferr = api.fabric_status(login.session_id)
		assert(fabric ~= nil, tostring(ferr))
		assert(fabric.main.status == 'running')
		assert(fabric.links.uart0.status == 'ready')

		local link, lerr = api.fabric_link_status(login.session_id, 'uart0')
		assert(link ~= nil, tostring(lerr))
		assert(link.link.peer_id == 'peer-a')
		assert(link.transfer.status == 'idle')
	end, { timeout = 1.0 })
end

function T.ui_capability_snapshot_collects_cap_dev_and_service_retained()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local api = assert(start_ui(scope, bus))

		seed_retained(bus, { 'cap', 'uart', 'ttyS0' }, { kind = 'uart' })
		seed_retained(bus, { 'dev', 'modem', 'mdm0' }, { kind = 'modem' })
		seed_retained(bus, { 'svc', 'hal', 'announce' }, { role = 'hal' })
		seed_retained(bus, { 'svc', 'hal', 'status' }, { state = 'running' })

		local login = assert((api.login('admin', 'secret')))
		local out, err = api.capability_snapshot(login.session_id)
		assert(out ~= nil, tostring(err))
		assert(out.capabilities['cap/uart/ttyS0'].kind == 'uart')
		assert(out.devices['dev/modem/mdm0'].kind == 'modem')
		assert(out.services.announce.hal.role == 'hal')
		assert(out.services.status.hal.state == 'running')
	end, { timeout = 1.0 })
end

function T.ui_firmware_and_transfer_helpers_call_fabric_rpc()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local api = assert(start_ui(scope, bus))

		spawn_fake_rpc_endpoint(scope, bus, 'fabric', 'send_firmware', function(payload)
			assert(payload.link_id == 'uart0')
			assert(type(payload.source) == 'table')
			assert(type(payload.source.open) == 'function')
			return { ok = true, transfer_id = 'tx-1' }
		end)

		spawn_fake_rpc_endpoint(scope, bus, 'fabric', 'transfer_status', function(payload)
			assert(payload.transfer_id == 'tx-1')
			return { ok = true, transfer = { id = 'tx-1', status = 'sending' } }
		end)

		spawn_fake_rpc_endpoint(scope, bus, 'fabric', 'transfer_abort', function(payload)
			assert(payload.transfer_id == 'tx-1')
			return { ok = true }
		end)

		local login = assert((api.login('admin', 'secret')))
		local source = {
			open = function()
				return {
					read = function() return nil, nil end,
					close = function() return true end,
				}
			end,
			size = function() return 4 end,
			sha256hex = function() return 'deadbeef' end,
			name = function() return 'fw.bin' end,
			format = function() return 'bin' end,
		}

		local sent, serr = api.firmware_send(login.session_id, 'uart0', source, {})
		assert(sent ~= nil, tostring(serr))
		assert(sent.transfer_id == 'tx-1')

		local st, terr = api.transfer_status(login.session_id, 'tx-1')
		assert(st ~= nil, tostring(terr))
		assert(st.transfer.status == 'sending')

		local aborted, aerr = api.transfer_abort(login.session_id, 'tx-1')
		assert(aborted ~= nil, tostring(aerr))
		assert(aborted.ok == true)
	end, { timeout = 1.0 })
end

function T.ui_retained_watch_streams_replay_done_and_live_changes()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local api = assert(start_ui(scope, bus))

		seed_retained(bus, { 'state', 'fabric', 'link', 'uart0' }, { status = 'ready' })
		local login = assert((api.login('admin', 'secret')))

		local watch, err = api.retained_watch(login.session_id, { 'state', 'fabric', 'link', '+' }, {
			replay_idle_s = 0.01,
		})
		assert(watch ~= nil, tostring(err))

		local ev1, e1 = watch:recv()
		assert(ev1 ~= nil, tostring(e1))
		assert(ev1.kind == 'retain')
		assert(ev1.phase == 'replay')
		assert(ev1.topic[4] == 'uart0')

		local ev2, e2 = watch:recv()
		assert(ev2 ~= nil, tostring(e2))
		assert(ev2.kind == 'replay_done')

		unretain(bus, { 'state', 'fabric', 'link', 'uart0' })
		local ev3, e3 = watch:recv()
		assert(ev3 ~= nil, tostring(e3))
		assert(ev3.kind == 'unretain')
		assert(ev3.phase == 'live')
		assert(ev3.topic[4] == 'uart0')

		assert(watch:close() == true)
	end, { timeout = 1.0 })
end

return T
