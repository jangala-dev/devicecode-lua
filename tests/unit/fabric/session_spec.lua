-- tests/unit/fabric/session_spec.lua

local busmod          = require 'bus'
local fibers          = require 'fibers'
local mailbox         = require 'fibers.mailbox'
local sleep           = require 'fibers.sleep'

local runfibers       = require 'tests.support.run_fibers'
local probe           = require 'tests.support.bus_probe'
local stack_diag      = require 'tests.support.stack_diag'
local fake_stream_mod = require 'tests.support.fake_stream_pair'
local fake_hal_mod    = require 'tests.support.fake_hal'

local base            = require 'devicecode.service_base'
local protocol        = require 'services.fabric.protocol'

local T = {}

local function connect_factory(bus)
	return function(principal)
		if principal ~= nil then
			return bus:connect({ principal = principal })
		end
		return bus:connect()
	end
end

local function base_link_cfg()
	return {
		peer_id = 'mcu-1',
		transport = {
			kind       = 'uart',
			serial_ref = 'uart-0',
		},
		export = {
			publish = {},
		},
		import = {
			publish = {},
			call    = {},
		},
		proxy_calls = {},
	}
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
		local msg = tostring(r.msg and r.msg.t or r.msg)
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

	assert(ok == true, explain('expected link ready state', diag, fake_hal, wire))
end

local function set_loaded(name, value)
	if value == nil then
		package.loaded[name] = nil
	else
		package.loaded[name] = value
	end
end

local function new_fake_transfer_module()
	local mod = {
		instances = {},
		last_ctor_args = nil,
		last_start = nil,
		incoming = {},
	}

	function mod.new(args)
		mod.last_ctor_args = args

		local seq = 0
		local statuses = {}

		local self = {}

		function self:start_send(source, meta)
			seq = seq + 1
			local id = 'xfer-' .. tostring(seq)

			statuses[id] = {
				transfer_id = id,
				status      = 'sending',
				meta        = meta,
				source      = source,
			}

			mod.last_start = {
				id     = id,
				source = source,
				meta   = meta,
			}

			local ok, err = args.send_frame({
				t    = 'xfer_begin',
				id   = id,
				meta = meta,
			})
			if ok ~= true then
				statuses[id] = nil
				return nil, err
			end

			return id, nil
		end

		function self:status(id)
			local st = statuses[id]
			if not st then
				return nil, 'unknown transfer'
			end

			return {
				transfer_id = st.transfer_id,
				status      = st.status,
				meta        = st.meta,
			}, nil
		end

		function self:abort(id, reason)
			local st = statuses[id]
			if not st then
				return nil, 'unknown transfer'
			end

			st.status = 'aborted'
			st.reason = reason

			local ok, err = args.send_frame({
				t      = 'xfer_abort',
				id     = id,
				reason = reason,
			})
			if ok ~= true then
				return nil, err
			end

			return true, nil
		end

		function self:abort_all(reason)
			for _, st in pairs(statuses) do
				st.status = 'aborted'
				st.reason = reason
			end
			return true
		end

		function self:is_transfer_message(msg)
			return type(msg) == 'table'
				and (msg.t == 'xfer_ready'
					or msg.t == 'xfer_ack'
					or msg.t == 'xfer_chunk'
					or msg.t == 'xfer_done'
					or msg.t == 'xfer_abort')
		end

		function self:handle_incoming(msg)
			mod.incoming[#mod.incoming + 1] = msg

			local st = msg and msg.id and statuses[msg.id] or nil
			if st and msg.t == 'xfer_ready' then
				st.status = 'ready'
			elseif st and msg.t == 'xfer_done' then
				st.status = 'done'
			elseif st and msg.t == 'xfer_abort' then
				st.status = 'aborted'
				st.reason = msg.reason
			end

			return true, nil
		end

		mod.instances[#mod.instances + 1] = self
		return self
	end

	return mod
end

local function load_session_with_fake_transfer(fake_transfer_mod)
	local old_transfer = package.loaded['services.fabric.transfer']
	local old_session  = package.loaded['services.fabric.session']

	set_loaded('services.fabric.transfer', fake_transfer_mod)
	set_loaded('services.fabric.session', nil)

	local ok, mod = pcall(require, 'services.fabric.session')

	set_loaded('services.fabric.transfer', old_transfer)
	set_loaded('services.fabric.session', old_session)

	assert(ok, tostring(mod))
	return mod
end

local function control_request(control_tx, req, diag, fake_hal, wire, timeout_s)
	local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })

	local job = {
		reply_tx = reply_tx,
	}
	for k, v in pairs(req or {}) do
		job[k] = v
	end

	local ok, err = control_tx:send(job)
	assert(ok == true, explain('failed to enqueue control job: ' .. tostring(err), diag, fake_hal, wire))

	local which, reply, rerr = recv_with_timeout(reply_rx:recv_op(), timeout_s or 0.5)
	assert(which == 'value', explain('timed out waiting for control reply', diag, fake_hal, wire))
	assert(reply ~= nil, explain('control reply mailbox ended: ' .. tostring(rerr), diag, fake_hal, wire))
	return reply
end

function T.session_control_send_blob_starts_transfer_and_status_is_queryable()
	runfibers.run(function(scope)
		local fake_transfer = new_fake_transfer_module()
		local session_mod = load_session_with_fake_transfer(fake_transfer)

		local bus = busmod.new()
		local session_conn = bus:connect()

		local diag = stack_diag.start(scope, bus, {
			{ label = 'state', topic = { 'state', '#' } },
			{ label = 'obs',   topic = { 'obs', '#' } },
			{ label = 'rpc',   topic = { 'rpc', '#' } },
		}, { max_records = 300 })

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

		local svc = base.new(session_conn, {
			name = 'fabric',
			env  = 'dev',
		})

		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local saw_xfer_begin = false

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
			local ack_line, aerr = protocol.encode_line(ack_msg)
			assert(ack_line ~= nil, explain('failed to encode hello_ack: ' .. tostring(aerr), diag, fake_hal, wire))
			wire_add(wire, 'tx', ack_line, ack_msg)
			assert(fibers.perform(peer_side:write_op(ack_line, '\n')))

			local which2, line2, err2 = recv_with_timeout(peer_side:read_line_op(), 0.75)
			assert(which2 == 'value', explain('timed out waiting for xfer_begin', diag, fake_hal, wire))
			assert(line2 ~= nil, explain('peer read error waiting for xfer_begin: ' .. tostring(err2), diag, fake_hal, wire))

			local xmsg, derr2 = protocol.decode_line(line2)
			wire_add(wire, 'rx', line2, xmsg)
			assert(xmsg ~= nil, explain('failed to decode xfer_begin: ' .. tostring(derr2), diag, fake_hal, wire))
			assert(xmsg.t == 'xfer_begin', explain('expected xfer_begin', diag, fake_hal, wire))
			assert(xmsg.id == 'xfer-1', explain('unexpected transfer id', diag, fake_hal, wire))
			assert(type(xmsg.meta) == 'table', explain('expected xfer_begin meta table', diag, fake_hal, wire))
			assert(xmsg.meta.kind == 'firmware', explain('expected firmware kind', diag, fake_hal, wire))
			assert(xmsg.meta.name == 'rp2350.uf2', explain('expected firmware name', diag, fake_hal, wire))
			saw_xfer_begin = true
		end)
		assert(ok_peer, tostring(perr))

		local ok_spawn, serr = scope:spawn(function()
			session_mod.run(session_conn, svc, {
				link_id    = 'mcu0',
				link       = base_link_cfg(),
				connect    = connect_factory(bus),
				node_id    = 'cm5-local',
				control_rx = control_rx,
			})
		end)
		assert(ok_spawn, tostring(serr))

		wait_for_link_ready(diag, fake_hal, wire, 0.75)

		local reply = control_request(control_tx, {
			op     = 'send_blob',
			source = {
				bytes = 'abc',
			},
			meta   = {
				kind = 'firmware',
				name = 'rp2350.uf2',
				size = 3,
			},
		}, diag, fake_hal, wire, 0.5)

		assert(type(reply) == 'table')
		assert(reply.ok == true, explain('expected send_blob ok reply', diag, fake_hal, wire))
		assert(reply.transfer_id == 'xfer-1', explain('unexpected transfer id from send_blob reply', diag, fake_hal, wire))

		local begin_seen = probe.wait_until(function()
			return saw_xfer_begin == true
		end, { timeout = 0.5, interval = 0.01 })
		assert(begin_seen == true, explain('expected peer to observe xfer_begin', diag, fake_hal, wire))

		local st = control_request(control_tx, {
			op          = 'transfer_status',
			transfer_id = 'xfer-1',
		}, diag, fake_hal, wire, 0.5)

		assert(type(st) == 'table')
		assert(st.ok == true, explain('expected transfer_status ok reply', diag, fake_hal, wire))
		assert(type(st.transfer) == 'table')
		assert(st.transfer.transfer_id == 'xfer-1')
		assert(st.transfer.status == 'sending')
		assert(type(st.transfer.meta) == 'table')
		assert(st.transfer.meta.kind == 'firmware')

		assert(type(fake_transfer.last_ctor_args) == 'table')
		assert(fake_transfer.last_ctor_args.link_id == 'mcu0')
		assert(fake_transfer.last_ctor_args.peer_id == 'mcu-1')

		assert(type(fake_transfer.last_start) == 'table')
		assert(fake_transfer.last_start.id == 'xfer-1')
		assert(type(fake_transfer.last_start.meta) == 'table')
		assert(fake_transfer.last_start.meta.name == 'rp2350.uf2')
	end, { timeout = 1.5 })
end

function T.session_control_transfer_abort_sends_xfer_abort_and_reports_aborted()
	runfibers.run(function(scope)
		local fake_transfer = new_fake_transfer_module()
		local session_mod = load_session_with_fake_transfer(fake_transfer)

		local bus = busmod.new()
		local session_conn = bus:connect()

		local diag = stack_diag.start(scope, bus, {
			{ label = 'state', topic = { 'state', '#' } },
			{ label = 'obs',   topic = { 'obs', '#' } },
			{ label = 'rpc',   topic = { 'rpc', '#' } },
		}, { max_records = 300 })

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

		local svc = base.new(session_conn, {
			name = 'fabric',
			env  = 'dev',
		})

		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local saw_xfer_begin = false
		local saw_xfer_abort = false

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
			local ack_line, aerr = protocol.encode_line(ack_msg)
			assert(ack_line ~= nil, explain('failed to encode hello_ack: ' .. tostring(aerr), diag, fake_hal, wire))
			wire_add(wire, 'tx', ack_line, ack_msg)
			assert(fibers.perform(peer_side:write_op(ack_line, '\n')))

			local which2, line2, err2 = recv_with_timeout(peer_side:read_line_op(), 0.75)
			assert(which2 == 'value', explain('timed out waiting for xfer_begin', diag, fake_hal, wire))
			assert(line2 ~= nil, explain('peer read error waiting for xfer_begin: ' .. tostring(err2), diag, fake_hal, wire))

			local begin_msg, derr2 = protocol.decode_line(line2)
			wire_add(wire, 'rx', line2, begin_msg)
			assert(begin_msg ~= nil, explain('failed to decode xfer_begin: ' .. tostring(derr2), diag, fake_hal, wire))
			assert(begin_msg.t == 'xfer_begin', explain('expected xfer_begin', diag, fake_hal, wire))
			assert(begin_msg.id == 'xfer-1', explain('unexpected transfer id', diag, fake_hal, wire))
			saw_xfer_begin = true

			local which3, line3, err3 = recv_with_timeout(peer_side:read_line_op(), 0.75)
			assert(which3 == 'value', explain('timed out waiting for xfer_abort', diag, fake_hal, wire))
			assert(line3 ~= nil, explain('peer read error waiting for xfer_abort: ' .. tostring(err3), diag, fake_hal, wire))

			local abort_msg, derr3 = protocol.decode_line(line3)
			wire_add(wire, 'rx', line3, abort_msg)
			assert(abort_msg ~= nil, explain('failed to decode xfer_abort: ' .. tostring(derr3), diag, fake_hal, wire))
			assert(abort_msg.t == 'xfer_abort', explain('expected xfer_abort', diag, fake_hal, wire))
			assert(abort_msg.id == 'xfer-1', explain('unexpected transfer id in abort', diag, fake_hal, wire))
			assert(abort_msg.reason == 'operator_cancel', explain('unexpected abort reason', diag, fake_hal, wire))
			saw_xfer_abort = true
		end)
		assert(ok_peer, tostring(perr))

		local ok_spawn, serr = scope:spawn(function()
			session_mod.run(session_conn, svc, {
				link_id    = 'mcu0',
				link       = base_link_cfg(),
				connect    = connect_factory(bus),
				node_id    = 'cm5-local',
				control_rx = control_rx,
			})
		end)
		assert(ok_spawn, tostring(serr))

		wait_for_link_ready(diag, fake_hal, wire, 0.75)

		local start_reply = control_request(control_tx, {
			op     = 'send_blob',
			source = {
				bytes = 'abcdef',
			},
			meta   = {
				kind = 'firmware',
				name = 'rp2350.uf2',
				size = 6,
			},
		}, diag, fake_hal, wire, 0.5)

		assert(start_reply.ok == true, explain('expected send_blob ok reply', diag, fake_hal, wire))
		assert(start_reply.transfer_id == 'xfer-1')

		local begin_seen = probe.wait_until(function()
			return saw_xfer_begin == true
		end, { timeout = 0.5, interval = 0.01 })
		assert(begin_seen == true, explain('expected peer to observe xfer_begin', diag, fake_hal, wire))

		local abort_reply = control_request(control_tx, {
			op          = 'transfer_abort',
			transfer_id = 'xfer-1',
			reason      = 'operator_cancel',
		}, diag, fake_hal, wire, 0.5)

		assert(type(abort_reply) == 'table')
		assert(abort_reply.ok == true, explain('expected transfer_abort ok reply', diag, fake_hal, wire))
		assert(abort_reply.err == nil)

		local abort_seen = probe.wait_until(function()
			return saw_xfer_abort == true
		end, { timeout = 0.5, interval = 0.01 })
		assert(abort_seen == true, explain('expected peer to observe xfer_abort', diag, fake_hal, wire))

		local st = control_request(control_tx, {
			op          = 'transfer_status',
			transfer_id = 'xfer-1',
		}, diag, fake_hal, wire, 0.5)

		assert(type(st) == 'table')
		assert(st.ok == true, explain('expected transfer_status ok reply after abort', diag, fake_hal, wire))
		assert(type(st.transfer) == 'table')
		assert(st.transfer.transfer_id == 'xfer-1')
		assert(st.transfer.status == 'aborted')
	end, { timeout = 1.5 })
end

return T
