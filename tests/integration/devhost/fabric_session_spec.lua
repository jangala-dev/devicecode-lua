local fibers       = require 'fibers'
local busmod       = require 'bus'
local mailbox      = require 'fibers.mailbox'
local blob_source  = require 'services.fabric.blob_source'
local authz        = require 'devicecode.authz'
local session      = require 'services.fabric.session'

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
		local ok, payload = pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table' and payload.ready == true
	end, { timeout = 1.0, interval = 0.01 })
end

local function wait_opening(conn, link_id)
	return probe.wait_until(function()
		local ok, payload = pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table' and payload.status == 'opening'
	end, { timeout = 1.0, interval = 0.01 })
end

local function get_link_state(conn, link_id)
	local ok, payload = pcall(function()
		return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
	end)
	if ok then
		return payload
	end
	return nil
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
