local fibers       = require 'fibers'
local busmod       = require 'bus'
local mailbox      = require 'fibers.mailbox'
local blob_source  = require 'services.fabric.blob_source'
local authz        = require 'devicecode.authz'
local protocol     = require 'services.fabric.protocol'
local session      = require 'services.fabric.session'
local safe         = require 'coxpcall'

local runfibers    = require 'tests.support.run_fibers'
local probe        = require 'tests.support.bus_probe'
local duplex       = require 'tests.support.duplex_stream'

local perform      = fibers.perform
local named_choice = fibers.named_choice
local sleep        = require 'fibers.sleep'

local T = {}

local function make_svc()
	return {
		now = function(self)
			return require('fibers').now()
		end,
		wall = function(self)
			return 'now'
		end,
		obs_log = function() end,
		obs_event = function() end,
	}
end

local function make_connect(bus)
	return function(principal)
		return bus:connect({ principal = principal })
	end
end

local function wait_ready(conn, link_id)
	return probe.wait_until(function()
		local ok, payload = safe.pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table' and payload.ready == true
	end, { timeout = 1.0, interval = 0.01 })
end

local function wait_opening(conn, link_id)
	return probe.wait_until(function()
		local ok, payload = safe.pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table' and payload.status == 'opening'
	end, { timeout = 1.0, interval = 0.01 })
end

local function get_link_state(conn, link_id)
	local ok, payload = safe.pcall(function()
		return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
	end)
	if ok then
		return payload
	end
	return nil
end

local function wait_transfer_status(conn, transfer_id, want_status)
	return probe.wait_until(function()
		local ok, payload = safe.pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'transfer', transfer_id }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table' and payload.status == want_status
	end, { timeout = 1.0, interval = 0.01 })
end

local function recv_mailbox(rx, timeout_s)
	local which, a = perform(named_choice {
		msg = rx:recv_op(),
		timer = sleep.sleep_op(timeout_s or 1.0):wrap(function() return true end),
	})

	if which == 'timer' then
		return nil, 'timeout'
	end
	if a == nil then
		return nil, 'closed'
	end
	return a, nil
end

local function write_frame(stream, msg)
	local line, lerr = protocol.encode_line(msg)
	assert(line ~= nil, tostring(lerr))

	local n, werr = perform(stream:write_op(line, '\n'))
	assert(n ~= nil, tostring(werr))
	return true
end

local function recv_frame(stream, timeout_s, label)
	local which, a, b = perform(named_choice {
		msg = stream:read_line_op(),
		timer = sleep.sleep_op(timeout_s or 1.0):wrap(function() return true end),
	})

	if which == 'timer' then
		error(('%s timed out'):format(label or 'frame read'), 0)
	end

	local line, err = a, b
	if line == nil then
		error(('%s failed: %s'):format(label or 'frame read', tostring(err)), 0)
	end

	local raw, derr = protocol.decode_line(line)
	assert(raw ~= nil, tostring(derr))

	local msg, verr = protocol.validate_message(raw)
	assert(msg ~= nil, tostring(verr))
	return msg
end

local function start_uart_cap(scope, bus, cap_id, stream)
	local conn = bus:connect({ principal = authz.service_principal('uart-cap-' .. tostring(cap_id)) })
	conn:retain({ 'cap', 'uart', cap_id, 'state' }, 'added')
	conn:retain({ 'cap', 'uart', cap_id, 'meta' }, { offerings = { open = true } })

	local ep = conn:bind({ 'cap', 'uart', cap_id, 'rpc', 'open' }, { queue_len = 8 })
	local ok_spawn, err = scope:spawn(function()
		while true do
			local msg = ep:recv()
			if not msg then return end
			if msg.reply_to ~= nil then
				conn:publish_one(msg.reply_to, {
					ok = true,
					reason = stream,
				}, { id = msg.id })
			end
		end
	end)
	assert(ok_spawn, tostring(err))
end

function T.devhost_sessions_bridge_publish_and_rpc_over_duplex_streams()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local a_stream, b_stream = duplex.new_pair()
		local a_ctrl_tx, a_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })
		local b_ctrl_tx, b_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })

		start_uart_cap(scope, bus, 'uart-a', a_stream)
		start_uart_cap(scope, bus, 'uart-b', b_stream)

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 1.0,
			},
			export = {
				publish = {
					{
						local_topic = { 'local', '+' },
						remote_topic = { 'remote', '+' },
						retain = false,
						queue_len = 8,
					},
				},
			},
			import = {
				publish = {},
				call = {},
			},
			proxy_calls = {
				{
					local_topic = { 'rpc', 'proxy', 'echo' },
					remote_topic = { 'rpc', 'remote', 'echo' },
					timeout_s = 2.0,
					queue_len = 8,
				},
			},
		}

		local link_b = {
			peer_id = 'node-a',
			transport = {
				kind = 'uart',
				cap_id = 'uart-b',
				open_timeout_s = 1.0,
			},
			export = {
				publish = {},
			},
			import = {
				publish = {
					{
						remote_topic = { 'remote', '+' },
						local_topic = { 'seen', '+' },
						retain = false,
					},
				},
				call = {
					{
						remote_topic = { 'rpc', 'remote', 'echo' },
						local_topic = { 'rpc', 'svc', 'echo' },
						timeout_s = 2.0,
					},
				},
			},
			proxy_calls = {},
		}

		local sink_data = { bytes = nil }

		local ok_spawn, err = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id = 'link-a',
				link = link_a,
				connect = connect,
				node_id = 'node-a',
				control_rx = a_ctrl_rx,
			})
		end)
		assert(ok_spawn, tostring(err))

		local ok_spawn2, err2 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-b') }), make_svc(), {
				link_id = 'link-b',
				link = link_b,
				connect = connect,
				node_id = 'node-b',
				control_rx = b_ctrl_rx,
				sink_factory = function(_meta)
					local parts = {}
					return {
						begin = function() return true end,
						write = function(_, _seq, _off, raw)
							parts[#parts + 1] = raw
							return true
						end,
						sha256hex = function()
							return require('services.fabric.checksum').sha256_hex(table.concat(parts))
						end,
						commit = function(_, info)
							sink_data.bytes = table.concat(parts)
							return { ok = true, info = info }, nil
						end,
						abort = function() return true end,
					}
				end,
			})
		end)
		assert(ok_spawn2, tostring(err2))

		local rpc_conn = bus:connect({ principal = authz.service_principal('rpc-echo') })
		local ep = rpc_conn:bind({ 'rpc', 'svc', 'echo' }, { queue_len = 8 })
		local ok_spawn3, err3 = scope:spawn(function()
			while true do
				local msg = ep:recv()
				if not msg then return end
				if msg.reply_to ~= nil then
					rpc_conn:publish_one(msg.reply_to, {
						echoed = msg.payload and msg.payload.value,
					}, { id = msg.id })
				end
			end
		end)
		assert(ok_spawn3, tostring(err3))

		assert(wait_ready(conn, 'link-a') == true, 'expected link-a to become ready')
		assert(wait_ready(conn, 'link-b') == true, 'expected link-b to become ready')

		conn:publish({ 'local', 'demo' }, { answer = 42 })
		local seen = probe.wait_payload(conn, { 'seen', 'demo' }, { timeout = 1.0 })
		assert(type(seen) == 'table')
		assert(seen.answer == 42)

		local reply, cerr = conn:call({ 'rpc', 'proxy', 'echo' }, { value = 'hi' }, { timeout = 2.0 })
		assert(reply ~= nil, tostring(cerr))
		assert(reply.echoed == 'hi')

		local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
		local source = blob_source.from_string('fw.bin', 'firmware-bytes', { format = 'bin' })
		local ok_job, jerr = a_ctrl_tx:send({
			op = 'send_blob',
			source = source,
			meta = {
				kind = 'firmware.rp2350',
				name = 'fw.bin',
				format = 'bin',
			},
			reply_tx = reply_tx,
		})
		assert(ok_job == true, tostring(jerr))

		local send_reply = assert(reply_rx:recv())
		assert(send_reply.ok == true)
		assert(type(send_reply.transfer_id) == 'string')

		local done = probe.wait_until(function()
			return sink_data.bytes == 'firmware-bytes'
		end, { timeout = 1.5, interval = 0.01 })
		assert(done == true, 'expected firmware transfer to complete')
	end, { timeout = 3.0 })
end

function T.devhost_session_control_rejects_send_blob_before_established()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local a_stream, _peer_stream = duplex.new_pair()
		local a_ctrl_tx, a_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })

		start_uart_cap(scope, bus, 'uart-a', a_stream)

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 1.0,
			},
			export = { publish = {} },
			import = { publish = {}, call = {} },
			proxy_calls = {},
		}

		local child, cerr = scope:child()
		assert(child ~= nil, tostring(cerr))

		local ok_spawn, err = child:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id = 'link-a',
				link = link_a,
				connect = connect,
				node_id = 'node-a',
				control_rx = a_ctrl_rx,
			})
		end)
		assert(ok_spawn, tostring(err))

		assert(wait_opening(conn, 'link-a') == true, 'expected link-a to enter opening state')

		local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
		local source = blob_source.from_string('fw.bin', 'firmware-bytes', { format = 'bin' })

		local ok_job, jerr = a_ctrl_tx:send({
			op = 'send_blob',
			source = source,
			meta = {
				kind = 'firmware.rp2350',
				name = 'fw.bin',
				format = 'bin',
			},
			reply_tx = reply_tx,
		})
		assert(ok_job == true, tostring(jerr))

		local reply, rerr = recv_mailbox(reply_rx, 1.0)
		assert(reply ~= nil, tostring(rerr))
		assert(reply.ok == false)
		assert(reply.err == 'session_not_established')
	end, { timeout = 2.0 })
end

function T.devhost_proxy_call_returns_no_route_when_remote_has_no_import_rule()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local a_stream, b_stream = duplex.new_pair()
		local a_ctrl_tx, a_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })
		local b_ctrl_tx, b_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })

		start_uart_cap(scope, bus, 'uart-a', a_stream)
		start_uart_cap(scope, bus, 'uart-b', b_stream)

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 1.0,
			},
			export = { publish = {} },
			import = { publish = {}, call = {} },
			proxy_calls = {
				{
					local_topic = { 'rpc', 'proxy', 'echo' },
					remote_topic = { 'rpc', 'remote', 'echo' },
					timeout_s = 2.0,
					queue_len = 8,
				},
			},
		}

		local link_b = {
			peer_id = 'node-a',
			transport = {
				kind = 'uart',
				cap_id = 'uart-b',
				open_timeout_s = 1.0,
			},
			export = { publish = {} },
			import = {
				publish = {},
				call = {},
			},
			proxy_calls = {},
		}

		local ok1, err1 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id = 'link-a',
				link = link_a,
				connect = connect,
				node_id = 'node-a',
				control_rx = a_ctrl_rx,
			})
		end)
		assert(ok1, tostring(err1))

		local ok2, err2 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-b') }), make_svc(), {
				link_id = 'link-b',
				link = link_b,
				connect = connect,
				node_id = 'node-b',
				control_rx = b_ctrl_rx,
			})
		end)
		assert(ok2, tostring(err2))

		assert(wait_ready(conn, 'link-a') == true, 'expected link-a to become ready')
		assert(wait_ready(conn, 'link-b') == true, 'expected link-b to become ready')

		local reply, err = conn:call({ 'rpc', 'proxy', 'echo' }, { value = 'hi' }, { timeout = 2.0 })
		assert(reply ~= nil, tostring(err))
		assert(type(reply) == 'table')
		assert(reply.ok == false)
		assert(tostring(reply.err):match('no_route'))
	end, { timeout = 3.0 })
end


function T.devhost_session_reconnects_after_successful_firmware_transfer()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local a_stream, peer_stream = duplex.new_pair()
		local a_ctrl_tx, a_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })
		start_uart_cap(scope, bus, 'uart-a', a_stream)

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 1.0,
			},
			keepalive = {
				hello_retry_s = 0.05,
				idle_ping_s = 1.0,
				stale_after_s = 1.0,
			},
			export = { publish = {} },
			import = { publish = {}, call = {} },
			proxy_calls = {},
		}

		local ok_spawn, err = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id = 'link-a',
				link = link_a,
				connect = connect,
				node_id = 'node-a',
				control_rx = a_ctrl_rx,
			})
		end)
		assert(ok_spawn, tostring(err))

		local hello1 = recv_frame(peer_stream, 1.0, 'initial peer hello')
		assert(hello1.t == 'hello')
		write_frame(peer_stream, protocol.hello_ack('node-b', { sid = 'peer-sid-1' }))

		assert(wait_ready(conn, 'link-a') == true, 'expected link-a to become ready')

		local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
		local source = blob_source.from_string('fw.bin', 'firmware-bytes', { format = 'bin' })
		local ok_job, jerr = a_ctrl_tx:send({
			op = 'send_blob',
			source = source,
			meta = {
				kind = 'firmware.rp2350',
				name = 'fw.bin',
				format = 'bin',
			},
			reply_tx = reply_tx,
		})
		assert(ok_job == true, tostring(jerr))

		local send_reply, rerr = recv_mailbox(reply_rx, 1.0)
		assert(send_reply ~= nil, tostring(rerr))
		assert(send_reply.ok == true)
		assert(type(send_reply.transfer_id) == 'string' and send_reply.transfer_id ~= '')

		local begin = recv_frame(peer_stream, 1.0, 'transfer begin')
		assert(begin.t == 'xfer_begin')
		assert(begin.id == send_reply.transfer_id)
		write_frame(peer_stream, protocol.xfer_ready(begin.id, true, 0, nil))

		local chunk = recv_frame(peer_stream, 1.0, 'transfer chunk')
		assert(chunk.t == 'xfer_chunk')
		assert(chunk.id == begin.id)
		write_frame(peer_stream, protocol.xfer_need(begin.id, 1, nil))

		local commit = recv_frame(peer_stream, 1.0, 'transfer commit')
		assert(commit.t == 'xfer_commit')
		assert(commit.id == begin.id)
		write_frame(peer_stream, protocol.xfer_done(begin.id, true, {
			bytes_written = #'firmware-bytes',
		}, nil))

		assert(wait_transfer_status(conn, begin.id, 'done') == true, 'expected transfer to reach done')

		local opening = probe.wait_until(function()
			local st = get_link_state(conn, 'link-a')
			return type(st) == 'table'
				and st.status == 'opening'
				and st.ready == false
				and st.established == false
				and st.reason == 'peer_reboot_expected'
		end, { timeout = 0.5, interval = 0.01 })
		assert(opening == true, 'expected link-a to drop back to opening after firmware transfer done')

		local hello2 = recv_frame(peer_stream, 0.30, 'reconnect hello')
		assert(hello2.t == 'hello')
		write_frame(peer_stream, protocol.hello_ack('node-b', { sid = 'peer-sid-2' }))

		local reconnected = probe.wait_until(function()
			local st = get_link_state(conn, 'link-a')
			return type(st) == 'table'
				and st.ready == true
				and st.peer_sid == 'peer-sid-2'
		end, { timeout = 0.5, interval = 0.01 })
		assert(reconnected == true, 'expected link-a to re-handshake after firmware transfer done')
	end, { timeout = 3.0 })
end

function T.devhost_session_sends_ping_while_peer_is_chatty_inbound()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local a_stream, peer_stream = duplex.new_pair()
		start_uart_cap(scope, bus, 'uart-a', a_stream)

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 1.0,
			},
			keepalive = {
				hello_retry_s = 0.2,
				idle_ping_s = 0.08,
				stale_after_s = 0.5,
			},
			export = { publish = {} },
			import = {
				publish = {
					{
						remote_topic = { 'remote', '+' },
						local_topic = { 'seen', '+' },
						retain = false,
					},
				},
				call = {},
			},
			proxy_calls = {},
		}

		local ok_spawn, err = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id = 'link-a',
				link = link_a,
				connect = connect,
				node_id = 'node-a',
			})
		end)
		assert(ok_spawn, tostring(err))

		local hello = recv_frame(peer_stream, 1.0, 'peer hello')
		assert(hello.t == 'hello')
		assert(hello.node == 'node-a')
		assert(hello.peer == 'node-b')

		write_frame(peer_stream, protocol.hello_ack('node-b', { sid = 'peer-sid-1' }))

		assert(wait_ready(conn, 'link-a') == true, 'expected link-a to become ready')

		local writer_done = false
		local ok_writer, writer_err = scope:spawn(function()
			for i = 1, 12 do
				write_frame(peer_stream, protocol.pub({ 'remote', 'demo' }, { seq = i }, false))
				sleep.sleep(0.02)
			end
			writer_done = true
		end)
		assert(ok_writer, tostring(writer_err))

		local ping = recv_frame(peer_stream, 0.20, 'outbound keepalive ping')
		assert(
			ping.t == 'ping',
			('expected ping while peer remained chatty, got %s'):format(tostring(ping.t))
		)
		assert(type(ping.sid) == 'string' and ping.sid ~= '')

		write_frame(peer_stream, protocol.pong({ sid = 'peer-sid-1' }))

		local pong_seen = probe.wait_until(function()
			local st = get_link_state(conn, 'link-a')
			return type(st) == 'table'
				and st.status ~= 'down'
				and st.ready == true
				and st.last_pong_at ~= nil
		end, { timeout = 0.5, interval = 0.01 })
		assert(pong_seen == true, 'expected link-a to record pong and remain ready')

		local writer_finished = probe.wait_until(function()
			return writer_done == true
		end, { timeout = 0.5, interval = 0.01 })
		assert(writer_finished == true, 'expected peer writer to finish')
	end, { timeout = 2.0 })
end

function T.devhost_session_transitions_down_after_repeated_bad_frames()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local a_stream, b_stream = duplex.new_pair()
		start_uart_cap(scope, bus, 'uart-a', a_stream)

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 1.0,
			},
			export = { publish = {} },
			import = { publish = {}, call = {} },
			proxy_calls = {},
		}

		local child, cerr = scope:child()
		assert(child ~= nil, tostring(cerr))

		local ok_spawn, err = child:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id = 'link-a',
				link = link_a,
				connect = connect,
				node_id = 'node-a',
			})
		end)
		assert(ok_spawn, tostring(err))

		assert(wait_opening(conn, 'link-a') == true, 'expected link-a to enter opening state')

		for _ = 1, 5 do
			local n, werr = perform(b_stream:write_op('not-json\n'))
			assert(n ~= nil, tostring(werr))
		end

		local ok = probe.wait_until(function()
			local st = get_link_state(conn, 'link-a')
			return type(st) == 'table'
				and st.status == 'down'
				and st.err == 'too_many_bad_frames'
		end, { timeout = 1.5, interval = 0.01 })
		assert(ok == true, 'expected link-a to transition down after repeated bad frames')

		local st, report, primary = perform(child:join_op())
		assert(st ~= 'ok', 'expected session child scope to finish not-ok after bad frames')
	end, { timeout = 3.0 })
end

return T
