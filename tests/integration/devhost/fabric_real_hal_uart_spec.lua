-- tests/integration/devhost/fabric_real_hal_uart_spec.lua

local fibers       = require 'fibers'
local busmod       = require 'bus'
local mailbox      = require 'fibers.mailbox'
local posix        = require 'posix'
local cjson        = require 'cjson.safe'

local authz        = require 'devicecode.authz'
local hal_service  = require 'services.hal'
local uart_manager = require 'services.hal.managers.uart'
local cap_sdk      = require 'services.hal.sdk.cap'
local session      = require 'services.fabric.session'
local blob_source  = require 'services.fabric.blob_source'
local checksum     = require 'services.fabric.checksum'

local runfibers    = require 'tests.support.run_fibers'
local probe        = require 'tests.support.bus_probe'
local pty          = require 'tests.support.pty'

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

local function setenv(name, value)
	local fn = posix.setenv
	if type(fn) ~= 'function' then
		local ok, stdlib = pcall(require, 'posix.stdlib')
		if ok and type(stdlib.setenv) == 'function' then
			fn = stdlib.setenv
		end
	end
	assert(type(fn) == 'function', 'luaposix setenv() is required for this test')
	local ok, err = fn(name, value, true)
	assert(ok ~= nil, tostring(err))
end

local function apply_hal_uart_config(conn, ports)
	conn:retain({ 'cfg', 'hal' }, {
		data = {
			schema = 'devicecode.config/hal/1',
			managers = {
				uart = {
					serial_ports = ports,
				},
			},
		},
	})
end

local function wait_uart_cap(conn, id, timeout_s)
	local listener = cap_sdk.new_cap_listener(conn, 'uart', id)
	local cap_ref, err = listener:wait_for_cap({ timeout = timeout_s or 2.0 })
	listener:close()
	assert(cap_ref ~= nil, tostring(err))
	return cap_ref
end

local function start_hal(scope, bus)
	setenv('DEVICECODE_CONFIG_DIR', '/tmp')

	local ok_spawn, err = scope:spawn(function()
		local conn = bus:connect({ principal = authz.service_principal('hal') })
		return hal_service.start(conn, { name = 'hal' })
	end)
	assert(ok_spawn, tostring(err))
end

local function wait_ready(conn, link_id)
	return probe.wait_until(function()
		local ok, payload = pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table' and payload.ready == true
	end, { timeout = 2.0, interval = 0.01 })
end

local function wait_opening(conn, link_id)
	return probe.wait_until(function()
		local ok, payload = pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table' and payload.status == 'opening'
	end, { timeout = 2.0, interval = 0.01 })
end

local function try_payload(conn, topic)
	local ok, payload = pcall(function()
		return probe.wait_payload(conn, topic, { timeout = 0.05 })
	end)
	if ok then
		return payload
	end
	return nil
end

local function failure_dump(conn, label)
	local snapshot = nil
	if uart_manager and uart_manager.debug_snapshot then
		snapshot = uart_manager.debug_snapshot()
	end

	return cjson.encode({
		label         = label,
		uart_snapshot = snapshot,
		link_a_state  = try_payload(conn, { 'state', 'fabric', 'link', 'link-a' }),
		link_b_state  = try_payload(conn, { 'state', 'fabric', 'link', 'link-b' }),
		link_a_diag   = try_payload(conn, { 'state', 'fabric', 'diag', 'link-a' }),
		link_b_diag   = try_payload(conn, { 'state', 'fabric', 'diag', 'link-b' }),
	})
end

local function assert_ready_or_dump(conn, link_id)
	local ok = wait_ready(conn, link_id)
	if ok ~= true then
		error(
			('expected %s to become ready\n%s'):format(
				link_id,
				tostring(failure_dump(conn, 'wait_ready_failed:' .. link_id))
			),
			0
		)
	end
end

local function recv_mailbox(rx, timeout_s)
	local which, a = perform(named_choice {
		msg = rx:recv_op(),
		timer = sleep.sleep_op(timeout_s or 1.0):wrap(function()
			return true
		end),
	})

	if which == 'timer' then
		return nil, 'timeout'
	end
	if a == nil then
		return nil, 'closed'
	end
	return a, nil
end

function T.devhost_fabric_sessions_bridge_publish_and_rpc_over_real_hal_uart_caps()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local pty_a = pty.open(scope)
		local pty_b = pty.open(scope)

		pty.bridge_pair(scope, pty_a, pty_b)

		-- Prove the PTY cross-wire itself works before involving HAL/fabric.
		pty.preflight_bridge_pair(scope, pty_a, pty_b, {
			timeout_s = 1.0,
			bytes_ab = '\001preflight-a-to-b\002',
			bytes_ba = '\003preflight-b-to-a\004',
		})

		start_hal(scope, bus)

		apply_hal_uart_config(conn, {
			{
				name = 'uart-a',
				path = pty_a.slave_name,
				baud = 115200,
				mode = '8N1',
			},
			{
				name = 'uart-b',
				path = pty_b.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		})

		wait_uart_cap(conn, 'uart-a', 2.0)
		wait_uart_cap(conn, 'uart-b', 2.0)

		local a_ctrl_tx, a_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })
		local b_ctrl_tx, b_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 2.0,
			},
			export = {
				publish = {
					{
						local_topic  = { 'local', '+' },
						remote_topic = { 'remote', '+' },
						retain       = false,
						queue_len    = 8,
					},
				},
			},
			import = {
				publish = {},
				call = {},
			},
			proxy_calls = {
				{
					local_topic  = { 'rpc', 'proxy', 'echo' },
					remote_topic = { 'rpc', 'remote', 'echo' },
					timeout_s    = 2.0,
					queue_len    = 8,
				},
			},
		}

		local link_b = {
			peer_id = 'node-a',
			transport = {
				kind = 'uart',
				cap_id = 'uart-b',
				open_timeout_s = 2.0,
			},
			export = {
				publish = {},
			},
			import = {
				publish = {
					{
						remote_topic = { 'remote', '+' },
						local_topic  = { 'seen', '+' },
						retain       = false,
					},
				},
				call = {
					{
						remote_topic = { 'rpc', 'remote', 'echo' },
						local_topic  = { 'rpc', 'svc', 'echo' },
						timeout_s    = 2.0,
					},
				},
			},
			proxy_calls = {},
		}

		local sink_data = { bytes = nil }

		local ok1, err1 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id    = 'link-a',
				link       = link_a,
				connect    = connect,
				node_id    = 'node-a',
				control_rx = a_ctrl_rx,
			})
		end)
		assert(ok1, tostring(err1))

		local ok2, err2 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-b') }), make_svc(), {
				link_id    = 'link-b',
				link       = link_b,
				connect    = connect,
				node_id    = 'node-b',
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
							return checksum.sha256_hex(table.concat(parts))
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
		assert(ok2, tostring(err2))

		local rpc_conn = bus:connect({ principal = authz.service_principal('rpc-echo') })
		local ep = rpc_conn:bind({ 'rpc', 'svc', 'echo' }, { queue_len = 8 })
		local ok3, err3 = scope:spawn(function()
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
		assert(ok3, tostring(err3))

		assert_ready_or_dump(conn, 'link-a')
		assert_ready_or_dump(conn, 'link-b')

		conn:publish({ 'local', 'demo' }, { answer = 42 })
		local seen = probe.wait_payload(conn, { 'seen', 'demo' }, { timeout = 1.5 })
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
				kind   = 'firmware.rp2350',
				name   = 'fw.bin',
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
		end, { timeout = 2.0, interval = 0.01 })
		assert(done == true, 'expected firmware transfer to complete')
	end, { timeout = 6.0 })
end

function T.devhost_fabric_control_rejects_send_blob_before_session_established()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local pty_a = pty.open(scope)

		start_hal(scope, bus)

		apply_hal_uart_config(conn, {
			{
				name = 'uart-a',
				path = pty_a.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		})

		wait_uart_cap(conn, 'uart-a', 2.0)

		local a_ctrl_tx, a_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 2.0,
			},
			export = { publish = {} },
			import = { publish = {}, call = {} },
			proxy_calls = {},
		}

		local ok1, err1 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id    = 'link-a',
				link       = link_a,
				connect    = connect,
				node_id    = 'node-a',
				control_rx = a_ctrl_rx,
			})
		end)
		assert(ok1, tostring(err1))

		local opening = wait_opening(conn, 'link-a')
		assert(opening == true, 'expected link-a to enter opening state')

		local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
		local source = blob_source.from_string('fw.bin', 'firmware-bytes', { format = 'bin' })

		local ok_job, jerr = a_ctrl_tx:send({
			op = 'send_blob',
			source = source,
			meta = {
				kind   = 'firmware.rp2350',
				name   = 'fw.bin',
				format = 'bin',
			},
			reply_tx = reply_tx,
		})
		assert(ok_job == true, tostring(jerr))

		local reply, rerr = recv_mailbox(reply_rx, 1.0)
		assert(reply ~= nil, tostring(rerr))
		assert(reply.ok == false)
		assert(reply.err == 'session_not_established')
	end, { timeout = 4.0 })
end

function T.devhost_fabric_proxy_call_propagates_no_route_over_real_hal_uart_caps()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local pty_a = pty.open(scope)
		local pty_b = pty.open(scope)

		pty.bridge_pair(scope, pty_a, pty_b)
		pty.preflight_bridge_pair(scope, pty_a, pty_b, {
			timeout_s = 1.0,
			bytes_ab = '\001preflight-a-to-b\002',
			bytes_ba = '\003preflight-b-to-a\004',
		})

		start_hal(scope, bus)

		apply_hal_uart_config(conn, {
			{
				name = 'uart-a',
				path = pty_a.slave_name,
				baud = 115200,
				mode = '8N1',
			},
			{
				name = 'uart-b',
				path = pty_b.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		})

		wait_uart_cap(conn, 'uart-a', 2.0)
		wait_uart_cap(conn, 'uart-b', 2.0)

		local a_ctrl_tx, a_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })
		local b_ctrl_tx, b_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 2.0,
			},
			export = { publish = {} },
			import = {
				publish = {},
				call = {},
			},
			proxy_calls = {
				{
					local_topic  = { 'rpc', 'proxy', 'echo' },
					remote_topic = { 'rpc', 'remote', 'echo' },
					timeout_s    = 2.0,
					queue_len    = 8,
				},
			},
		}

		local link_b = {
			peer_id = 'node-a',
			transport = {
				kind = 'uart',
				cap_id = 'uart-b',
				open_timeout_s = 2.0,
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
				link_id    = 'link-a',
				link       = link_a,
				connect    = connect,
				node_id    = 'node-a',
				control_rx = a_ctrl_rx,
			})
		end)
		assert(ok1, tostring(err1))

		local ok2, err2 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-b') }), make_svc(), {
				link_id    = 'link-b',
				link       = link_b,
				connect    = connect,
				node_id    = 'node-b',
				control_rx = b_ctrl_rx,
			})
		end)
		assert(ok2, tostring(err2))

		assert_ready_or_dump(conn, 'link-a')
		assert_ready_or_dump(conn, 'link-b')

		local reply, err = conn:call({ 'rpc', 'proxy', 'echo' }, { value = 'hi' }, { timeout = 2.0 })
		assert(reply ~= nil, tostring(err))
		assert(type(reply) == 'table')
		assert(reply.ok == false)
		assert(tostring(reply.err):match('no_route'))
	end, { timeout = 6.0 })
end

function T.devhost_fabric_transfer_aborts_on_receiver_sha256_mismatch_over_real_hal_uart_caps()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local pty_a = pty.open(scope)
		local pty_b = pty.open(scope)

		pty.bridge_pair(scope, pty_a, pty_b)
		pty.preflight_bridge_pair(scope, pty_a, pty_b, {
			timeout_s = 1.0,
			bytes_ab = '\001preflight-a-to-b\002',
			bytes_ba = '\003preflight-b-to-a\004',
		})

		start_hal(scope, bus)

		apply_hal_uart_config(conn, {
			{
				name = 'uart-a',
				path = pty_a.slave_name,
				baud = 115200,
				mode = '8N1',
			},
			{
				name = 'uart-b',
				path = pty_b.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		})

		wait_uart_cap(conn, 'uart-a', 2.0)
		wait_uart_cap(conn, 'uart-b', 2.0)

		local a_ctrl_tx, a_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })
		local b_ctrl_tx, b_ctrl_rx = mailbox.new(8, { full = 'reject_newest' })

		local aborted_reason = nil

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 2.0,
			},
			export = { publish = {} },
			import = { publish = {}, call = {} },
			proxy_calls = {},
		}

		local link_b = {
			peer_id = 'node-a',
			transport = {
				kind = 'uart',
				cap_id = 'uart-b',
				open_timeout_s = 2.0,
			},
			export = { publish = {} },
			import = { publish = {}, call = {} },
			proxy_calls = {},
		}

		local ok1, err1 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id    = 'link-a',
				link       = link_a,
				connect    = connect,
				node_id    = 'node-a',
				control_rx = a_ctrl_rx,
			})
		end)
		assert(ok1, tostring(err1))

		local ok2, err2 = scope:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-b') }), make_svc(), {
				link_id    = 'link-b',
				link       = link_b,
				connect    = connect,
				node_id    = 'node-b',
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
							return string.rep('0', 64)
						end,
						commit = function()
							return { ok = true }, nil
						end,
						abort = function(_, reason)
							aborted_reason = reason
							return true
						end,
					}
				end,
			})
		end)
		assert(ok2, tostring(err2))

		assert_ready_or_dump(conn, 'link-a')
		assert_ready_or_dump(conn, 'link-b')

		local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
		local source = blob_source.from_string('fw.bin', 'firmware-bytes', { format = 'bin' })

		local ok_job, jerr = a_ctrl_tx:send({
			op = 'send_blob',
			source = source,
			meta = {
				kind   = 'firmware.rp2350',
				name   = 'fw.bin',
				format = 'bin',
			},
			reply_tx = reply_tx,
		})
		assert(ok_job == true, tostring(jerr))

		local send_reply = assert(reply_rx:recv())
		assert(send_reply.ok == true)
		assert(type(send_reply.transfer_id) == 'string')

		local transfer_id = send_reply.transfer_id

		local ok = probe.wait_until(function()
			local st = try_payload(conn, { 'state', 'fabric', 'transfer', transfer_id })
			return type(st) == 'table' and st.status == 'aborted'
		end, { timeout = 2.5, interval = 0.01 })
		assert(ok == true, 'expected transfer to abort on sha256 mismatch')

		local st = probe.wait_payload(conn, { 'state', 'fabric', 'transfer', transfer_id }, { timeout = 0.5 })
		assert(type(st) == 'table')
		assert(st.status == 'aborted')
		assert(tostring(st.err):match('sha256_mismatch'))
		assert(aborted_reason == 'sha256_mismatch')
	end, { timeout = 7.0 })
end

function T.devhost_fabric_session_transitions_down_after_repeated_bad_frames_over_real_hal_uart_caps()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect({ principal = authz.service_principal('test') })
		local connect = make_connect(bus)

		local pty_a = pty.open(scope)

		start_hal(scope, bus)

		apply_hal_uart_config(conn, {
			{
				name = 'uart-a',
				path = pty_a.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		})

		wait_uart_cap(conn, 'uart-a', 2.0)

		local link_a = {
			peer_id = 'node-b',
			transport = {
				kind = 'uart',
				cap_id = 'uart-a',
				open_timeout_s = 2.0,
			},
			export = { publish = {} },
			import = { publish = {}, call = {} },
			proxy_calls = {},
		}

		local child, cerr = scope:child()
		assert(child ~= nil, tostring(cerr))

		local ok1, err1 = child:spawn(function()
			session.run(bus:connect({ principal = authz.service_principal('sess-a') }), make_svc(), {
				link_id = 'link-a',
				link = link_a,
				connect = connect,
				node_id = 'node-a',
			})
		end)
		assert(ok1, tostring(err1))

		local opening = wait_opening(conn, 'link-a')
		assert(opening == true, 'expected link-a to enter opening state')

		for _ = 1, 5 do
			local ok, err = pty_a:write('not-json\n')
			assert(ok == true, tostring(err))
		end

		local down = probe.wait_until(function()
			local st = try_payload(conn, { 'state', 'fabric', 'link', 'link-a' })
			return type(st) == 'table'
				and st.status == 'down'
				and st.err == 'too_many_bad_frames'
		end, { timeout = 2.0, interval = 0.01 })
		assert(down == true, 'expected link-a to transition down after repeated bad frames')

		local jst, report, primary = perform(child:join_op())
		assert(jst ~= 'ok', 'expected session child scope to terminate not-ok after bad frames')
	end, { timeout = 5.0 })
end

return T
