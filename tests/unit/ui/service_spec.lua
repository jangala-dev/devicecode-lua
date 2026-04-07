-- tests/unit/ui/service_spec.lua

local sleep       = require 'fibers.sleep'
local busmod      = require 'bus'

local blob_source = require 'services.fabric.blob_source'
local runfibers   = require 'tests.support.run_fibers'
local probe       = require 'tests.support.bus_probe'

local ui_service  = require 'services.ui'

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
			if not msg then
				return
			end

			calls[#calls + 1] = {
				topic   = msg.topic,
				payload = msg.payload,
				id      = msg.id,
			}

			if msg.reply_to ~= nil then
				conn:publish(msg.reply_to, {
					ok        = true,
					persisted = false,
				}, { id = msg.id })
			end
		end
	end)
	assert(ok_spawn, tostring(err))

	local ok = probe.wait_until(function()
		return ready == true
	end, { timeout = 0.5, interval = 0.01 })

	assert(ok == true, 'expected fake config acceptor to be ready')
	return calls
end

local function spawn_fake_rpc_endpoint(scope, bus, service_name, method_name, handler, calls)
	calls = calls or {}
	local ready = false

	local ok_spawn, err = scope:spawn(function()
		local conn = bus:connect()
		local ep = conn:bind({ 'rpc', service_name, method_name }, {
			queue_len = 8,
		})
		ready = true

		while true do
			local msg, _ = ep:recv()
			if not msg then
				return
			end

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

	local ok = probe.wait_until(function()
		return ready == true
	end, { timeout = 0.5, interval = 0.01 })

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
		assert(type(out.user) == 'table')
		assert(out.user.id == 'admin')
		assert(type(out.user.roles) == 'table')
		assert(out.user.roles[1] == 'admin')

		local msg, merr = sub:recv()
		assert(msg ~= nil, tostring(merr))
		assert(type(msg.payload) == 'table')
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

function T.ui_config_set_round_trips_via_bus()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local calls = {}

		spawn_fake_config_acceptor(scope, bus, 'net', calls)

		local api = assert(start_ui(scope, bus))

		local login, lerr = api.login('admin', 'secret')
		assert(login ~= nil, tostring(lerr))

		local out, err = api.config_set(login.session_id, 'net', {
			schema = 'devicecode.net/1',
			answer = 42,
		})
		assert(out ~= nil, tostring(err))
		assert(out.ok == true)
		assert(out.persisted == false)

		local seen = probe.wait_until(function()
			return #calls >= 1
		end, { timeout = 0.5, interval = 0.01 })

		assert(seen == true, 'expected fake config acceptor to receive a request')
		assert(#calls >= 1)

		local call = calls[1]
		assert(type(call.topic) == 'table')
		assert(call.topic[1] == 'config')
		assert(call.topic[2] == 'net')
		assert(call.topic[3] == 'set')
		assert(type(call.payload) == 'table')
		assert(type(call.payload.data) == 'table')
		assert(call.payload.data.schema == 'devicecode.net/1')
		assert(call.payload.data.answer == 42)
	end, { timeout = 1.0 })
end

function T.ui_rpc_call_round_trips_via_endpoint()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local calls = {}

		spawn_fake_rpc_endpoint(scope, bus, 'hal', 'dump', function(payload, msg)
			return {
				ok      = true,
				echo    = payload,
				method  = 'dump',
				reply_to = msg.reply_to ~= nil,
			}
		end, calls)

		local api = assert(start_ui(scope, bus))

		local login, lerr = api.login('admin', 'secret')
		assert(login ~= nil, tostring(lerr))

		local out, err = api.rpc_call(login.session_id, 'hal', 'dump', {
			packages = { 'network', 'firewall' },
		}, 0.5)

		assert(out ~= nil, tostring(err))
		assert(out.ok == true)
		assert(out.method == 'dump')
		assert(out.reply_to == true)
		assert(type(out.echo) == 'table')
		assert(type(out.echo.packages) == 'table')
		assert(out.echo.packages[1] == 'network')
		assert(out.echo.packages[2] == 'firewall')

		local seen = probe.wait_until(function()
			return #calls >= 1
		end, { timeout = 0.5, interval = 0.01 })

		assert(seen == true, 'expected fake rpc endpoint to receive a request')
		assert(#calls >= 1)

		local call = calls[1]
		assert(type(call.topic) == 'table')
		assert(call.topic[1] == 'rpc')
		assert(call.topic[2] == 'hal')
		assert(call.topic[3] == 'dump')
		assert(type(call.payload) == 'table')
		assert(type(call.payload.packages) == 'table')
		assert(call.payload.packages[1] == 'network')
	end, { timeout = 1.0 })
end

function T.ui_firmware_send_round_trips_blob_source_via_endpoint_and_emits_audit()
	runfibers.run(function(scope)
		local bus  = busmod.new()
		local conn = bus:connect()
		local calls = {}

		spawn_fake_rpc_endpoint(scope, bus, 'fabric', 'send_firmware', function(payload, _msg)
			assert(type(payload) == 'table')
			assert(payload.link_id == 'mcu0')
			assert(type(payload.source) == 'table')
			assert(type(payload.meta) == 'table')

			local r = payload.source:open()
			local bytes, err = r:read(1024)
			assert(bytes ~= nil, tostring(err))
			assert(bytes == 'firmware-bytes')
			r:close()

			return {
				ok = true,
				transfer_id = 'xfer-123',
			}
		end, calls)

		local api = assert(start_ui(scope, bus))
		local sub = conn:subscribe({ 'obs', 'audit', 'ui', 'firmware_send' }, {
			queue_len = 1,
			full      = 'reject_newest',
		})

		local login, lerr = api.login('admin', 'secret')
		assert(login ~= nil, tostring(lerr))

		local src = blob_source.from_string('rp2350.uf2', 'firmware-bytes', {
			format = 'uf2',
		})

		local out, err = api.firmware_send(login.session_id, 'mcu0', src, {
			kind = 'firmware.rp2350',
		})
		assert(out ~= nil, tostring(err))
		assert(out.ok == true)
		assert(out.transfer_id == 'xfer-123')

		local seen = probe.wait_until(function()
			return #calls >= 1
		end, { timeout = 0.5, interval = 0.01 })
		assert(seen == true, 'expected fabric send_firmware call')

		local call = calls[1]
		assert(call.topic[1] == 'rpc')
		assert(call.topic[2] == 'fabric')
		assert(call.topic[3] == 'send_firmware')
		assert(call.payload.link_id == 'mcu0')
		assert(type(call.payload.meta) == 'table')
		assert(call.payload.meta.kind == 'firmware.rp2350')
		assert(call.payload.meta.name == 'rp2350.uf2')
		assert(call.payload.meta.format == 'uf2')

		local msg, merr = sub:recv()
		assert(msg ~= nil, tostring(merr))
		assert(type(msg.payload) == 'table')
		assert(msg.payload.user == 'admin')
		assert(msg.payload.transfer == 'xfer-123')
		assert(msg.payload.ok == true)
	end, { timeout = 1.0 })
end

function T.ui_transfer_status_round_trips_via_endpoint()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local calls = {}

		spawn_fake_rpc_endpoint(scope, bus, 'fabric', 'transfer_status', function(payload, _msg)
			return {
				ok          = true,
				transfer_id = payload.transfer_id,
				status      = 'sending',
				bytes_done  = 32,
			}
		end, calls)

		local api = assert(start_ui(scope, bus))

		local login, lerr = api.login('admin', 'secret')
		assert(login ~= nil, tostring(lerr))

		local out, err = api.transfer_status(login.session_id, 'xfer-123')
		assert(out ~= nil, tostring(err))
		assert(out.ok == true)
		assert(out.transfer_id == 'xfer-123')
		assert(out.status == 'sending')
		assert(out.bytes_done == 32)

		local seen = probe.wait_until(function()
			return #calls >= 1
		end, { timeout = 0.5, interval = 0.01 })
		assert(seen == true, 'expected fabric transfer_status call')

		local call = calls[1]
		assert(call.topic[1] == 'rpc')
		assert(call.topic[2] == 'fabric')
		assert(call.topic[3] == 'transfer_status')
		assert(call.payload.transfer_id == 'xfer-123')
	end, { timeout = 1.0 })
end

function T.ui_transfer_abort_round_trips_via_endpoint_and_emits_audit()
	runfibers.run(function(scope)
		local bus  = busmod.new()
		local conn = bus:connect()
		local calls = {}

		spawn_fake_rpc_endpoint(scope, bus, 'fabric', 'transfer_abort', function(payload, _msg)
			return {
				ok          = true,
				transfer_id = payload.transfer_id,
				aborted     = true,
			}
		end, calls)

		local api = assert(start_ui(scope, bus))
		local sub = conn:subscribe({ 'obs', 'audit', 'ui', 'transfer_abort' }, {
			queue_len = 1,
			full      = 'reject_newest',
		})

		local login, lerr = api.login('admin', 'secret')
		assert(login ~= nil, tostring(lerr))

		local out, err = api.transfer_abort(login.session_id, 'xfer-123')
		assert(out ~= nil, tostring(err))
		assert(out.ok == true)
		assert(out.aborted == true)

		local seen = probe.wait_until(function()
			return #calls >= 1
		end, { timeout = 0.5, interval = 0.01 })
		assert(seen == true, 'expected fabric transfer_abort call')

		local call = calls[1]
		assert(call.topic[1] == 'rpc')
		assert(call.topic[2] == 'fabric')
		assert(call.topic[3] == 'transfer_abort')
		assert(call.payload.transfer_id == 'xfer-123')

		local msg, merr = sub:recv()
		assert(msg ~= nil, tostring(merr))
		assert(type(msg.payload) == 'table')
		assert(msg.payload.user == 'admin')
		assert(msg.payload.transfer == 'xfer-123')
		assert(msg.payload.ok == true)
	end, { timeout = 1.0 })
end

return T
