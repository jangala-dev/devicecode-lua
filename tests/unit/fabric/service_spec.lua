-- tests/unit/fabric/service_spec.lua

local cjson           = require 'cjson.safe'

local busmod          = require 'bus'
local fibers          = require 'fibers'
local sleep           = require 'fibers.sleep'

local runfibers       = require 'tests.support.run_fibers'
local probe           = require 'tests.support.bus_probe'
local stack_diag      = require 'tests.support.stack_diag'
local fake_stream_mod = require 'tests.support.fake_stream_pair'
local fake_hal_mod    = require 'tests.support.fake_hal'

local protocol        = require 'services.fabric.protocol'
local fabric_service  = require 'services.fabric'

local T = {}

local function connect_factory(bus)
	return function(principal)
		if principal ~= nil then
			return bus:connect({ principal = principal })
		end
		return bus:connect()
	end
end

local function trace_specs()
	return {
		{ label = 'svc',   topic = { 'svc', '#' } },
		{ label = 'cfg',   topic = { 'config', '#' } },
		{ label = 'state', topic = { 'state', '#' } },
		{ label = 'obs',   topic = { 'obs', '#' } },
		{ label = 'rpc',   topic = { 'rpc', '#' } },
	}
end

local function base_fabric_cfg()
	return {
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind       = 'uart',
					serial_ref = 'uart-0',
				},
				export = {
					publish = {
						{
							src    = { 'config', 'mcu' },
							dst    = { 'config', 'device' },
							retain = true,
						},
					},
				},
				import = {
					publish = {
						{
							src    = { 'state', '#' },
							dst    = { 'peer', 'mcu-1', 'state', '#' },
							retain = true,
						},
					},
					call = {
						{
							src       = { 'rpc', 'hal', 'read_state' },
							dst       = { 'rpc', 'hal', 'read_state' },
							timeout_s = 0.5,
						},
					},
				},
				proxy_calls = {
					{
						src       = { 'rpc', 'peer', 'mcu-1', 'hal', 'dump' },
						dst       = { 'rpc', 'hal', 'dump' },
						timeout_s = 0.5,
					},
				},
			},
		},
	}
end

local function spawn_fabric(scope, bus)
	local ok_spawn, err = scope:spawn(function()
		fabric_service.start(bus:connect(), {
			name    = 'fabric',
			env     = 'dev',
			node_id = 'cm5-local',
			connect = connect_factory(bus),
		})
	end)
	assert(ok_spawn, tostring(err))
end

local function recv_with_timeout(ev, timeout_s)
	local which, a, b = fibers.perform(fibers.named_choice({
		value = ev,
		timer = sleep.sleep_op(timeout_s):wrap(function() return true end),
	}))
	return which, a, b
end

local function new_wire_trace()
	return {}
end

local function wire_add(wire, dir, raw, decoded)
	wire[#wire + 1] = {
		t   = fibers.now(),
		dir = dir,
		raw = raw,
		msg = decoded,
	}
end

local function render_wire(wire)
	local out = {
		('wire.records=%d'):format(#wire),
		'-- wire trace --',
	}

	for i = 1, #wire do
		local r = wire[i]
		local msg = cjson.encode(r.msg) or tostring(r.msg)
		out[#out + 1] = ('[%0.6f] %s %s'):format(
			tonumber(r.t) or 0,
			tostring(r.dir),
			msg
		)
	end

	return table.concat(out, '\n')
end

local function explain(message, diag, fake_hal, wire)
	return table.concat({
		tostring(message),
		'',
		stack_diag.render(diag, { max_records = 200 }),
		'',
		stack_diag.render_fake_hal(fake_hal, { max_calls = 80 }),
		'',
		render_wire(wire),
	}, '\n')
end

local function assert_hello_frame(msg, diag, fake_hal, wire)
	assert(msg ~= nil, explain('expected hello frame, got nil', diag, fake_hal, wire))
	assert(msg.t == 'hello', explain('expected hello frame', diag, fake_hal, wire))
	assert(type(msg.node) == 'string' and msg.node ~= '', explain('hello.node missing', diag, fake_hal, wire))
	assert(type(msg.sid) == 'string' and msg.sid ~= '', explain('hello.sid missing', diag, fake_hal, wire))
	assert(type(msg.proto) == 'number', explain('hello.proto missing', diag, fake_hal, wire))
	assert(type(msg.caps) == 'table', explain('hello.caps missing', diag, fake_hal, wire))
	assert(msg.caps.blob_transfer == true, explain('hello.blob_transfer missing', diag, fake_hal, wire))
end

local function wait_until_trace_has(diag, predicate, timeout, interval)
	return probe.wait_until(function()
		local records = diag.records or {}
		for i = 1, #records do
			local rec = records[i]
			if predicate(rec) then
				return true
			end
		end
		return false
	end, {
		timeout  = timeout or 0.75,
		interval = interval or 0.01,
	})
end

local function wait_for_link_ready(diag, fake_hal, wire, timeout)
	local ok = wait_until_trace_has(diag, function(rec)
		return rec.label == 'state'
			and type(rec.topic) == 'table'
			and rec.topic[1] == 'state'
			and rec.topic[2] == 'fabric'
			and rec.topic[3] == 'link'
			and rec.topic[4] == 'mcu0'
			and type(rec.payload) == 'table'
			and rec.payload.status == 'ready'
			and rec.payload.ready == true
	end, timeout or 0.75, 0.01)

	assert(ok == true, explain('expected fabric link ready state', diag, fake_hal, wire))
end

function T.fabric_opens_hal_serial_ref_and_imports_remote_publish()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local cfg_conn = bus:connect()
		local probe_conn = bus:connect()

		local diag = stack_diag.start(scope, bus, trace_specs(), { max_records = 300 })

		local sub = probe_conn:subscribe({ 'peer', 'mcu-1', 'state', '#' }, {
			queue_len = 8,
			full      = 'drop_oldest',
		})

		local hal_side, peer_side = fake_stream_mod.new_pair()
		local wire = new_wire_trace()

		local fake_hal = fake_hal_mod.new({
			scripted = {
				open_serial_stream = function(req, _msg)
					assert(type(req) == 'table')
					assert(req.ref == 'uart-0')
					return {
						ok     = true,
						stream = hal_side,
						info   = {
							ref  = req.ref,
							baud = 115200,
							mode = '8N1',
						},
					}
				end,
			},
		})
		fake_hal:start(bus:connect(), { name = 'hal' })

		local ok_peer, perr = scope:spawn(function()
			local which1, line, err = recv_with_timeout(peer_side:read_line_op(), 0.5)
			assert(which1 == 'value', explain('timed out waiting for hello', diag, fake_hal, wire))
			assert(line ~= nil, explain('peer read error waiting for hello: ' .. tostring(err), diag, fake_hal, wire))

			local msg, derr = protocol.decode_line(line)
			wire_add(wire, 'rx', line, msg)
			assert(msg ~= nil, explain('failed to decode hello: ' .. tostring(derr), diag, fake_hal, wire))
			assert_hello_frame(msg, diag, fake_hal, wire)

			local ack_msg = protocol.hello_ack('mcu-1', {
				sid = 'peer-sid-1',
			})
			local s, serr = protocol.encode_line(ack_msg)
			assert(s ~= nil, explain('failed to encode hello_ack: ' .. tostring(serr), diag, fake_hal, wire))
			wire_add(wire, 'tx', s, ack_msg)
			local n, werr = fibers.perform(peer_side:write_op(s, '\n'))
			assert(n ~= nil, explain('failed to write hello_ack: ' .. tostring(werr), diag, fake_hal, wire))

			local pub_msg = protocol.pub({ 'state', 'health' }, { ok = true, source = 'mcu' }, true)
			local pub_line, perr2 = protocol.encode_line(pub_msg)
			assert(pub_line ~= nil, explain('failed to encode pub: ' .. tostring(perr2), diag, fake_hal, wire))
			wire_add(wire, 'tx', pub_line, pub_msg)
			local n2, werr2 = fibers.perform(peer_side:write_op(pub_line, '\n'))
			assert(n2 ~= nil, explain('failed to write pub: ' .. tostring(werr2), diag, fake_hal, wire))
		end)
		assert(ok_peer, tostring(perr))

		spawn_fabric(scope, bus)
		cfg_conn:retain({ 'config', 'fabric' }, base_fabric_cfg())

		local which, msg, err = recv_with_timeout(sub:recv_op(), 0.75)
		assert(which == 'value', explain('timed out waiting for imported remote publish', diag, fake_hal, wire))
		assert(msg ~= nil, explain('subscription ended waiting for imported remote publish: ' .. tostring(err), diag, fake_hal, wire))

		assert(msg.topic[1] == 'peer')
		assert(msg.topic[2] == 'mcu-1')
		assert(msg.topic[3] == 'state')
		assert(msg.topic[4] == 'health')
		assert(type(msg.payload) == 'table')
		assert(msg.payload.ok == true)
		assert(msg.payload.source == 'mcu')

		local calls = fake_hal:calls_for('open_serial_stream')
		assert(#calls >= 1)
		assert(type(calls[1].req) == 'table')
		assert(calls[1].req.ref == 'uart-0')
	end, { timeout = 1.5 })
end

function T.fabric_exports_local_publish_to_remote_peer()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local cfg_conn = bus:connect()
		local pub_conn = bus:connect()

		local diag = stack_diag.start(scope, bus, trace_specs(), { max_records = 300 })

		local hal_side, peer_side = fake_stream_mod.new_pair()
		local wire = new_wire_trace()
		local peer_ready = false

		local fake_hal = fake_hal_mod.new({
			scripted = {
				open_serial_stream = function(req, _msg)
					return {
						ok     = true,
						stream = hal_side,
						info   = {
							ref  = req.ref,
							baud = 115200,
							mode = '8N1',
						},
					}
				end,
			},
		})
		fake_hal:start(bus:connect(), { name = 'hal' })

		local ok_peer, perr = scope:spawn(function()
			local which1, line1, err1 = recv_with_timeout(peer_side:read_line_op(), 0.5)
			assert(which1 == 'value', explain('timed out waiting for hello', diag, fake_hal, wire))
			assert(line1 ~= nil, explain('peer read error waiting for hello: ' .. tostring(err1), diag, fake_hal, wire))

			local hello, derr1 = protocol.decode_line(line1)
			wire_add(wire, 'rx', line1, hello)
			assert(hello ~= nil, explain('failed to decode hello: ' .. tostring(derr1), diag, fake_hal, wire))
			assert_hello_frame(hello, diag, fake_hal, wire)

			local ack_msg = protocol.hello_ack('mcu-1', {
				sid = 'peer-sid-1',
			})
			local ack = assert(protocol.encode_line(ack_msg))
			wire_add(wire, 'tx', ack, ack_msg)
			assert(fibers.perform(peer_side:write_op(ack, '\n')))
			peer_ready = true

			local which2, line2, err2 = recv_with_timeout(peer_side:read_line_op(), 0.75)
			assert(which2 == 'value', explain('timed out waiting for exported publish', diag, fake_hal, wire))
			assert(line2 ~= nil, explain('peer read error waiting for exported publish: ' .. tostring(err2), diag, fake_hal, wire))

			local pub, derr2 = protocol.decode_line(line2)
			wire_add(wire, 'rx', line2, pub)
			assert(pub ~= nil, explain('failed to decode exported pub: ' .. tostring(derr2), diag, fake_hal, wire))
			assert(pub.t == 'pub')
			assert(pub.retain == true)
			assert(pub.topic[1] == 'config')
			assert(pub.topic[2] == 'device')
			assert(type(pub.payload) == 'table')
			assert(pub.payload.answer == 42)
		end)
		assert(ok_peer, tostring(perr))

		spawn_fabric(scope, bus)
		cfg_conn:retain({ 'config', 'fabric' }, base_fabric_cfg())

		local ready = probe.wait_until(function()
			return #fake_hal:calls_for('open_serial_stream') >= 1 and peer_ready == true
		end, { timeout = 0.5, interval = 0.005 })

		assert(ready == true, explain('expected fabric link to be ready before export test', diag, fake_hal, wire))
		wait_for_link_ready(diag, fake_hal, wire, 0.75)

		local exporter_started = wait_until_trace_has(diag, function(rec)
			return rec.label == 'obs'
				and type(rec.payload) == 'table'
				and rec.topic
				and rec.topic[1] == 'obs'
				and rec.topic[2] == 'log'
				and rec.topic[3] == 'fabric'
				and rec.topic[4] == 'info'
				and rec.payload.what == 'export_publish_started'
				and rec.payload.link_id == 'mcu0'
		end, 0.5, 0.01)

		assert(exporter_started == true, explain('expected export publisher to be started before export test', diag, fake_hal, wire))

		pub_conn:retain({ 'config', 'mcu' }, {
			answer = 42,
		})
	end, { timeout = 1.5 })
end

function T.fabric_proxies_local_call_to_remote_peer()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local cfg_conn = bus:connect()
		local req_conn = bus:connect()

		local diag = stack_diag.start(scope, bus, trace_specs(), { max_records = 300 })

		local hal_side, peer_side = fake_stream_mod.new_pair()
		local wire = new_wire_trace()
		local peer_ready = false

		local fake_hal = fake_hal_mod.new({
			scripted = {
				open_serial_stream = function(req, _msg)
					return {
						ok     = true,
						stream = hal_side,
						info   = {
							ref  = req.ref,
							baud = 115200,
							mode = '8N1',
						},
					}
				end,
			},
		})
		fake_hal:start(bus:connect(), { name = 'hal' })

		local ok_peer, perr = scope:spawn(function()
			local which1, line1, err1 = recv_with_timeout(peer_side:read_line_op(), 0.5)
			assert(which1 == 'value', explain('timed out waiting for hello', diag, fake_hal, wire))
			assert(line1 ~= nil, explain('peer read error waiting for hello: ' .. tostring(err1), diag, fake_hal, wire))

			local hello, derr1 = protocol.decode_line(line1)
			wire_add(wire, 'rx', line1, hello)
			assert(hello ~= nil, explain('failed to decode hello: ' .. tostring(derr1), diag, fake_hal, wire))
			assert_hello_frame(hello, diag, fake_hal, wire)

			local ack_msg = protocol.hello_ack('mcu-1', {
				sid = 'peer-sid-1',
			})
			local ack = assert(protocol.encode_line(ack_msg))
			wire_add(wire, 'tx', ack, ack_msg)
			assert(fibers.perform(peer_side:write_op(ack, '\n')))
			peer_ready = true

			local which2, line2, err2 = recv_with_timeout(peer_side:read_line_op(), 0.75)
			assert(which2 == 'value', explain('timed out waiting for proxied call', diag, fake_hal, wire))
			assert(line2 ~= nil, explain('peer read error waiting for proxied call: ' .. tostring(err2), diag, fake_hal, wire))

			local call_msg, derr = protocol.decode_line(line2)
			wire_add(wire, 'rx', line2, call_msg)
			assert(call_msg ~= nil, explain('failed to decode proxied call: ' .. tostring(derr), diag, fake_hal, wire))
			assert(call_msg.t == 'call')
			assert(call_msg.topic[1] == 'rpc')
			assert(call_msg.topic[2] == 'hal')
			assert(call_msg.topic[3] == 'dump')
			assert(type(call_msg.payload) == 'table')
			assert(call_msg.payload.ask == 'status')

			local reply_msg = protocol.reply_ok(call_msg.id, { ok = true, remote = 'mcu-1' })
			local reply_line = assert(protocol.encode_line(reply_msg))
			wire_add(wire, 'tx', reply_line, reply_msg)
			assert(fibers.perform(peer_side:write_op(reply_line, '\n')))
		end)
		assert(ok_peer, tostring(perr))

		spawn_fabric(scope, bus)
		cfg_conn:retain({ 'config', 'fabric' }, base_fabric_cfg())

		local ready = probe.wait_until(function()
			return #fake_hal:calls_for('open_serial_stream') >= 1 and peer_ready == true
		end, { timeout = 0.5, interval = 0.005 })

		assert(ready == true, explain('expected fabric link to be ready before proxied call test', diag, fake_hal, wire))
		wait_for_link_ready(diag, fake_hal, wire, 0.75)

		local proxy_started = wait_until_trace_has(diag, function(rec)
			return rec.label == 'obs'
				and type(rec.payload) == 'table'
				and rec.topic
				and rec.topic[1] == 'obs'
				and rec.topic[2] == 'log'
				and rec.topic[3] == 'fabric'
				and rec.topic[4] == 'info'
				and rec.payload.what == 'proxy_call_started'
				and rec.payload.link_id == 'mcu0'
		end, 0.5, 0.01)

		assert(proxy_started == true, explain('expected proxy endpoint to be started before proxied call test', diag, fake_hal, wire))

		local reply, err = req_conn:call({ 'rpc', 'peer', 'mcu-1', 'hal', 'dump' }, {
			ask = 'status',
		}, {
			timeout = 0.75,
		})

		assert(reply ~= nil, explain('expected proxied reply, got: ' .. tostring(err), diag, fake_hal, wire))
		assert(type(reply) == 'table')
		assert(reply.ok == true)
		assert(reply.remote == 'mcu-1')
	end, { timeout = 1.5 })
end

function T.fabric_proxies_incoming_remote_call_to_local_hal()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local cfg_conn = bus:connect()

		local diag = stack_diag.start(scope, bus, trace_specs(), { max_records = 300 })

		local hal_side, peer_side = fake_stream_mod.new_pair()
		local wire = new_wire_trace()

		local fake_hal = fake_hal_mod.new({
			scripted = {
				open_serial_stream = function(req, _msg)
					return {
						ok     = true,
						stream = hal_side,
						info   = {
							ref  = req.ref,
							baud = 115200,
							mode = '8N1',
						},
					}
				end,

				read_state = function(req, _msg)
					return {
						ok    = true,
						found = true,
						data  = 'abc123',
						key   = req and req.key or nil,
					}
				end,
			},
		})
		fake_hal:start(bus:connect(), { name = 'hal' })

		local ok_peer, perr = scope:spawn(function()
			local which1, line1, err1 = recv_with_timeout(peer_side:read_line_op(), 0.5)
			assert(which1 == 'value', explain('timed out waiting for hello', diag, fake_hal, wire))
			assert(line1 ~= nil, explain('peer read error waiting for hello: ' .. tostring(err1), diag, fake_hal, wire))

			local hello, derr = protocol.decode_line(line1)
			wire_add(wire, 'rx', line1, hello)
			assert(hello ~= nil, explain('failed to decode hello: ' .. tostring(derr), diag, fake_hal, wire))
			assert_hello_frame(hello, diag, fake_hal, wire)

			local ack_msg = protocol.hello_ack('mcu-1', {
				sid = 'peer-sid-1',
			})
			local ack = assert(protocol.encode_line(ack_msg))
			wire_add(wire, 'tx', ack, ack_msg)
			assert(fibers.perform(peer_side:write_op(ack, '\n')))

			local incoming_msg = protocol.call('call-1', { 'rpc', 'hal', 'read_state' }, {
				ns  = 'config',
				key = 'services',
			}, 500)
			local incoming = assert(protocol.encode_line(incoming_msg))
			wire_add(wire, 'tx', incoming, incoming_msg)
			assert(fibers.perform(peer_side:write_op(incoming, '\n')))

			local which2, reply_line, rerr = recv_with_timeout(peer_side:read_line_op(), 0.75)
			assert(which2 == 'value', explain('timed out waiting for reply to remote call', diag, fake_hal, wire))
			assert(reply_line ~= nil, explain('peer read error waiting for reply to remote call: ' .. tostring(rerr), diag, fake_hal, wire))

			local reply_msg, derr2 = protocol.decode_line(reply_line)
			wire_add(wire, 'rx', reply_line, reply_msg)
			assert(reply_msg ~= nil, explain('failed to decode reply to remote call: ' .. tostring(derr2), diag, fake_hal, wire))
			assert(reply_msg.t == 'reply')
			assert(reply_msg.corr == 'call-1')
			assert(reply_msg.ok == true)
			assert(type(reply_msg.payload) == 'table')
			assert(reply_msg.payload.found == true)
			assert(reply_msg.payload.data == 'abc123')
			assert(reply_msg.payload.key == 'services')
		end)
		assert(ok_peer, tostring(perr))

		spawn_fabric(scope, bus)
		cfg_conn:retain({ 'config', 'fabric' }, base_fabric_cfg())

		local seen = probe.wait_until(function()
			return #fake_hal:calls_for('read_state') >= 1
		end, { timeout = 0.75, interval = 0.01 })

		assert(seen == true, explain('expected HAL read_state to be called', diag, fake_hal, wire))

		local calls = fake_hal:calls_for('read_state')
		assert(#calls >= 1)
		assert(type(calls[1].req) == 'table')
		assert(calls[1].req.ns == 'config')
		assert(calls[1].req.key == 'services')
	end, { timeout = 1.5 })
end

function T.fabric_accepts_symmetric_peer_hello_and_imports_remote_publish()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local cfg_conn = bus:connect()
		local probe_conn = bus:connect()

		local diag = stack_diag.start(scope, bus, trace_specs(), { max_records = 300 })

		local sub = probe_conn:subscribe({ 'peer', 'mcu-1', 'state', '#' }, {
			queue_len = 8,
			full      = 'drop_oldest',
		})

		local hal_side, peer_side = fake_stream_mod.new_pair()
		local wire = new_wire_trace()

		local fake_hal = fake_hal_mod.new({
			scripted = {
				open_serial_stream = function(req, _msg)
					return {
						ok     = true,
						stream = hal_side,
						info   = {
							ref  = req.ref,
							baud = 115200,
							mode = '8N1',
						},
					}
				end,
			},
		})
		fake_hal:start(bus:connect(), { name = 'hal' })

		local ok_peer, perr = scope:spawn(function()
			local which1, line, err = recv_with_timeout(peer_side:read_line_op(), 0.5)
			assert(which1 == 'value', explain('timed out waiting for hello', diag, fake_hal, wire))
			assert(line ~= nil, explain('peer read error waiting for hello: ' .. tostring(err), diag, fake_hal, wire))

			local msg, derr = protocol.decode_line(line)
			wire_add(wire, 'rx', line, msg)
			assert(msg ~= nil, explain('failed to decode hello: ' .. tostring(derr), diag, fake_hal, wire))
			assert_hello_frame(msg, diag, fake_hal, wire)

			local peer_hello = protocol.hello('mcu-1', 'cm5-local', {
				pub           = true,
				call          = true,
				blob_transfer = true,
			}, {
				sid = 'peer-sid-1',
			})
			local ph, perr2 = protocol.encode_line(peer_hello)
			assert(ph ~= nil, explain('failed to encode peer hello: ' .. tostring(perr2), diag, fake_hal, wire))
			wire_add(wire, 'tx', ph, peer_hello)
			assert(fibers.perform(peer_side:write_op(ph, '\n')))

			local pub_msg = protocol.pub({ 'state', 'health' }, { ok = true, source = 'mcu' }, true)
			local pub_line, perr3 = protocol.encode_line(pub_msg)
			assert(pub_line ~= nil, explain('failed to encode pub: ' .. tostring(perr3), diag, fake_hal, wire))
			wire_add(wire, 'tx', pub_line, pub_msg)
			assert(fibers.perform(peer_side:write_op(pub_line, '\n')))
		end)
		assert(ok_peer, tostring(perr))

		spawn_fabric(scope, bus)
		cfg_conn:retain({ 'config', 'fabric' }, base_fabric_cfg())

		local which, msg, err = recv_with_timeout(sub:recv_op(), 0.75)
		assert(which == 'value', explain('timed out waiting for imported remote publish after symmetric hello', diag, fake_hal, wire))
		assert(msg ~= nil, explain('subscription ended waiting for imported remote publish after symmetric hello: ' .. tostring(err), diag, fake_hal, wire))

		assert(msg.topic[1] == 'peer')
		assert(msg.topic[2] == 'mcu-1')
		assert(msg.topic[3] == 'state')
		assert(msg.topic[4] == 'health')
		assert(type(msg.payload) == 'table')
		assert(msg.payload.ok == true)
		assert(msg.payload.source == 'mcu')
	end, { timeout = 1.5 })
end

return T
