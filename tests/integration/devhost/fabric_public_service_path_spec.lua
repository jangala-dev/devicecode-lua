-- tests/integration/devhost/fabric_public_service_path_spec.lua
--
-- Whole public Fabric service-path integration tests on devhost fakes.
--
-- These deliberately exercise the public configured-link entry point:
--
--   fabric.start(conn, opts)
--     -> service shell
--     -> compiled generation
--     -> composed link
--     -> local bus bridge runtime
--     -> transfer manager
--     -> JSONL line transport
--
-- They use a deterministic in-memory JSONL line transport rather than the HAL UART
-- driver.  The separate fabric_hal_uart_smoke_spec covers the current HAL UART
-- open path.

local busmod   = require 'bus'
local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'

local probe    = require 'tests.support.bus_probe'
local runfibers = require 'tests.support.run_fibers'

local fabric   = require 'services.fabric'
local protocol = require 'services.fabric.protocol'
local topics   = require 'services.fabric.topics'
local hal_transport = require 'services.fabric.hal_transport'

local T = {}

local function assert_eq(a, b, msg)
	assert(a == b, msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
end

local function assert_true(v, msg)
	assert(v == true, msg or ('expected true, got ' .. tostring(v)))
end


local function join_topic(topic)
	if type(topic) ~= 'table' then return tostring(topic) end
	local parts = {}
	for i = 1, #topic do parts[#parts + 1] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

local function compact_value(v, depth)
	depth = depth or 0
	local tv = type(v)
	if tv == 'string' then
		return string.format('%q', v)
	end
	if tv ~= 'table' then
		return tostring(v)
	end
	if depth >= 2 then return '{...}' end
	local parts = {}
	local n = 0
	for i = 1, #v do
		n = n + 1
		parts[#parts + 1] = compact_value(v[i], depth + 1)
		if n >= 8 then break end
	end
	for k, val in pairs(v) do
		if type(k) ~= 'number' then
			n = n + 1
			parts[#parts + 1] = tostring(k) .. '=' .. compact_value(val, depth + 1)
			if n >= 12 then break end
		end
	end
	return '{' .. table.concat(parts, ', ') .. '}'
end

local function frame_summary(frame)
	if type(frame) ~= 'table' then return tostring(frame) end
	local parts = { tostring(frame.type or '?') }
	if frame.sid then parts[#parts + 1] = 'sid=' .. tostring(frame.sid) end
	if frame.node then parts[#parts + 1] = 'node=' .. tostring(frame.node) end
	if frame.id then parts[#parts + 1] = 'id=' .. tostring(frame.id) end
	if frame.xfer_id then parts[#parts + 1] = 'xfer_id=' .. tostring(frame.xfer_id) end
	if frame.target then parts[#parts + 1] = 'target=' .. tostring(frame.target) end
	if frame.offset ~= nil then parts[#parts + 1] = 'offset=' .. tostring(frame.offset) end
	if frame.next ~= nil then parts[#parts + 1] = 'next=' .. tostring(frame.next) end
	if frame.size ~= nil then parts[#parts + 1] = 'size=' .. tostring(frame.size) end
	if frame.digest then parts[#parts + 1] = 'digest=' .. tostring(frame.digest) end
	if frame.chunk_digest then parts[#parts + 1] = 'chunk_digest=' .. tostring(frame.chunk_digest) end
	if frame.topic then parts[#parts + 1] = 'topic=' .. join_topic(frame.topic) end
	if frame.ok ~= nil then parts[#parts + 1] = 'ok=' .. tostring(frame.ok) end
	if frame.err then parts[#parts + 1] = 'err=' .. tostring(frame.err) end
	return table.concat(parts, ' ')
end

local function chat(label, value)
	local msg = '[fabric-pair-send-blob] ' .. tostring(label)
	if value ~= nil then
		if type(value) == 'table' and value.type then
			msg = msg .. ': ' .. frame_summary(value)
		else
			msg = msg .. ': ' .. compact_value(value)
		end
	end
	io.stderr:write(msg .. '\n')
end

local function dump_transport(label, transport)
	chat(label .. ' written_count', #transport.written)
	for i, frame in ipairs(transport.written) do
		io.stderr:write(('[fabric-pair-send-blob] %s[%d] %s\n'):format(label, i, frame_summary(frame)))
	end
	chat(label .. ' flushes', transport.flushes and transport.flushes() or '?')
	chat(label .. ' closes', transport.closes and transport.closes() or '?')
	chat(label .. ' close_reason', transport.close_reason and transport.close_reason() or nil)
end

local function trace_transport(label, transport)
	local orig = transport.session.write_line_op
	function transport.session:write_line_op(line)
		local frame = protocol.decode_line(line)
		if frame then
			chat(label .. ' write_line', frame)
		else
			chat(label .. ' write_line undecodable', line)
		end
		return orig(self, line)
	end
end

local function copy_frame(frame)
	local out = {}
	for k, v in pairs(frame or {}) do
		if type(v) == 'table' then
			local t = {}
			for k2, v2 in pairs(v) do t[k2] = v2 end
			out[k] = t
		else
			out[k] = v
		end
	end
	return out
end

local function new_line_transport()
	local in_tx, in_rx = mailbox.new(64, { full = 'reject_newest' })
	local written = {}
	local flushes = 0
	local closes = 0
	local close_reason

	local session = {}

	function session:read_line_op()
		return in_rx:recv_op():wrap(function(frame)
			if frame == nil then
				return nil, in_rx:why() or 'closed'
			end

			local line, err = protocol.encode_line(frame)
			if not line then
				return nil, err
			end
			return line, nil
		end)
	end

	function session:write_line_op(line)
		local frame, err = protocol.decode_line(line)
		if not frame then
			return fibers.always(nil, err)
		end
		written[#written + 1] = copy_frame(frame)
		return fibers.always(true, nil)
	end

	function session:flush_op()
		flushes = flushes + 1
		return fibers.always(true, nil)
	end

	function session:terminate(reason)
		closes = closes + 1
		close_reason = reason
		in_tx:close(reason or 'transport terminated')
		return true, nil
	end

	return {
		session = session,
		in_tx = in_tx,
		written = written,
		flushes = function() return flushes end,
		closes = function() return closes end,
		close_reason = function() return close_reason end,
	}
end


local function wait_retained_payload_where(conn, topic, label, pred, opts)
	opts = opts or {}
	local view = conn:retained_view(topic)
	local value = probe.wait_versioned_until(label, function ()
		return view:version()
	end, function (seen)
		return view:changed_op(seen)
	end, function ()
		local msg = view:get(topic)
		local payload = msg and msg.payload or nil
		if pred(payload) then return payload end
		return nil
	end, opts)
	view:close()
	return value
end

local function wait_written(label, transport, predicate, opts)
	opts = opts or {}
	local last
	local ok = probe.wait_until(function()
		for i = 1, #transport.written do
			local frame = transport.written[i]
			if predicate(frame, i) then
				last = frame
				return true
			end
		end
		return false
	end, { timeout = opts.timeout or 1.5, interval = opts.interval or 0.002 })

	if not ok then
		error('timed out waiting for written frame: ' .. tostring(label), 0)
	end

	return last
end

local function send_inbound(transport, frame)
	local ok, err = fibers.perform(transport.in_tx:send_op(frame))
	assert_true(ok, tostring(err))
end

local function base_config(extra_link)
	extra_link = extra_link or {}

	local link = {
		id = 'link-a',
		peer_id = 'node-b',
		transport = {
			source = 'test',
			class = 'jsonl',
			id = 'link-a',
		},
		session = {
			hello_interval_s = 5.0,
			ping_interval_s = 5.0,
			liveness_timeout_s = 5.0,
		},
		bridge = extra_link.bridge or {},
		transfer = extra_link.transfer,
		queues = extra_link.queues,
	}

	return {
		schema = fabric.config.SCHEMA,
		local_node = 'node-a',
		links = { link },
	}
end

local function wrap_session_op(session)
	local wrapped, err = hal_transport.wrap_transport(session)
	return fibers.always(wrapped, err)
end

local function default_link_overrides(transport)
	if not transport then return nil end
	return {
		['link-a'] = {
			open_transport_op = function ()
				return wrap_session_op(transport.session)
			end,
		},
	}
end

local function start_public_fabric(scope, conn, cfg, transport, opts)
	opts = opts or {}
	local ok, err = scope:spawn(function()
		fabric.start(conn, {
			name = opts.name or 'fabric',
			env = 'test',
			config = cfg,
				link_overrides = opts.link_overrides or default_link_overrides(transport),
			config_queue_len = opts.config_queue_len,
		})
	end)
	assert_true(ok, tostring(err))
end

local function link_config(params)
	params = params or {}
	return {
		schema = fabric.config.SCHEMA,
		local_node = params.local_node or 'node-a',
		links = {
			{
				id = params.id or 'link-a',
				peer_id = params.peer_id or 'node-b',
				transport = {
					source = 'test',
					class = 'jsonl',
					id = params.id or 'link-a',
				},
				session = params.session or {
					hello_interval_s = 5.0,
					ping_interval_s = 5.0,
					liveness_timeout_s = 5.0,
				},
				bridge = params.bridge or {},
				transfer = params.transfer,
				queues = params.queues,
			},
		},
	}
end

local function connect_line_transports(a, b)
	local write_a = a.session.write_line_op
	function a.session:write_line_op(line)
		local frame = assert(protocol.decode_line(line))
		write_a(self, line)
		return b.in_tx:send_op(copy_frame(frame))
	end

	local write_b = b.session.write_line_op
	function b.session:write_line_op(line)
		local frame = assert(protocol.decode_line(line))
		write_b(self, line)
		return a.in_tx:send_op(copy_frame(frame))
	end
end

function T.fabric_start_bridges_local_and_remote_retained_state_over_composed_link()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local transport = new_line_transport()

		conn:retain({ 'local', 'retained', 'flag' }, { enabled = true })

		local cfg = base_config({
			bridge = {
				imports = {
					{ ['local'] = { 'mirror' }, remote = { 'remote', 'in' } },
				},
				exports = {
					{
						['local'] = { 'local', 'retained' },
						remote = { 'remote', 'out' },
						publish = false,
						retain = true,
					},
				},
			},
		})

		start_public_fabric(scope, conn, cfg, transport)

		wait_written('initial hello', transport, function(frame)
			return frame.type == 'hello' and frame.node == 'node-a'
		end)

		-- Retained exports are now session-scoped. They are replayed only after
		-- fabric.session has established a peer session.
		send_inbound(transport, assert(protocol.hello_ack('peer-sid', 'node-b')))

		local retained_pub = wait_written('exported retained local bus state', transport, function(frame)
			return frame.type == 'pub'
				and frame.retain == true
				and frame.topic[1] == 'remote'
				and frame.topic[2] == 'out'
				and frame.topic[3] == 'flag'
		end)
		assert_eq(retained_pub.payload.enabled, true)

		send_inbound(transport, assert(protocol.pub({ 'remote', 'in', 'status' }, { online = true }, true)))

		local mirrored = probe.wait_retained_payload(conn, { 'mirror', 'status' }, {
			timeout = 1.5,
		})
		assert_eq(mirrored.online, true)
	end, { timeout = 4.0 })
end

function T.fabric_start_pair_bridges_publish_retained_and_rpc_over_composed_links()
	runfibers.run(function(scope)
		local bus_a = busmod.new()
		local bus_b = busmod.new()
		local conn_a = bus_a:connect()
		local conn_b = bus_b:connect()
		local transport_a = new_line_transport()
		local transport_b = new_line_transport()
		connect_line_transports(transport_a, transport_b)

		local cfg_a = link_config({
			local_node = 'node-a',
			id = 'link-a',
			peer_id = 'node-b',
			bridge = {
				exports = {
					{
						['local'] = { 'a', 'pub' },
						remote = { 'wire', 'pub' },
						publish = true,
						retain = true,
					},
				},
				rpc = {
					outbound = {
						{
							['local'] = { 'a', 'rpc', 'echo' },
							remote = { 'svc', 'echo' },
							timeout_s = 1.0,
						},
					},
				},
			},
		})

		local cfg_b = link_config({
			local_node = 'node-b',
			id = 'link-a',
			peer_id = 'node-a',
			bridge = {
				imports = {
					{
						['local'] = { 'b', 'pub' },
						remote = { 'wire', 'pub' },
					},
				},
				rpc = {
					inbound = {
						{
							['local'] = { 'b', 'rpc', 'echo' },
							remote = { 'svc', 'echo' },
							timeout_s = 1.0,
						},
					},
				},
			},
		})

		start_public_fabric(scope, conn_a, cfg_a, transport_a)
		start_public_fabric(scope, conn_b, cfg_b, transport_b)

		wait_written('node-a hello', transport_a, function(frame)
			return frame.type == 'hello' and frame.node == 'node-a'
		end)
		wait_written('node-b hello', transport_b, function(frame)
			return frame.type == 'hello' and frame.node == 'node-b'
		end)
		wait_written('node-a hello_ack', transport_a, function(frame)
			return frame.type == 'hello_ack' and frame.node == 'node-a'
		end)
		wait_written('node-b hello_ack', transport_b, function(frame)
			return frame.type == 'hello_ack' and frame.node == 'node-b'
		end)

		local ep_b = conn_b:bind({ 'b', 'rpc', 'echo' })
		local ok_handler, handler_err = scope:spawn(function()
			while true do
				local req = ep_b:recv()
				if not req then return end
				req:reply({ echoed = req.payload })
			end
		end)
		assert_true(ok_handler, tostring(handler_err))

		local sub_b = conn_b:subscribe({ 'b', 'pub', '#' }, {
			queue_len = 8,
			full = 'reject_newest',
		})
		conn_a:publish({ 'a', 'pub', 'one' }, { value = 11 })
		local msg = probe.wait_message(conn_b, { 'b', 'pub', '#' }, {
			timeout = 1.5,
			sub = sub_b,
		})
		sub_b:unsubscribe()
		assert_eq(msg.topic[1], 'b')
		assert_eq(msg.topic[2], 'pub')
		assert_eq(msg.topic[3], 'one')
		assert_eq(msg.payload.value, 11)

		conn_a:retain({ 'a', 'pub', 'answer' }, { value = 42 })
		local retained = probe.wait_retained_payload(conn_b, { 'b', 'pub', 'answer' }, {
			timeout = 1.5,
		})
		assert_eq(retained.value, 42)

		local value, err = conn_a:call({ 'a', 'rpc', 'echo' }, { hello = 'world' }, {
			timeout = 1.5,
		})
		assert(value ~= nil, tostring(err))
		assert_eq(value.echoed.hello, 'world')
	end, { timeout = 5.0 })
end

function T.fabric_start_config_replacement_restarts_generation_and_closes_old_transport()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local transport_a = new_line_transport()
		local transport_b = new_line_transport()

		start_public_fabric(scope, conn, nil, nil, {
			link_overrides = {
				['link-a'] = { open_transport_op = function () return wrap_session_op(transport_a.session) end },
				['link-b'] = { open_transport_op = function () return wrap_session_op(transport_b.session) end },
			},
		})

		conn:retain(topics.cfg(), link_config({
			id = 'link-a',
			peer_id = 'node-b',
		}))

		wait_written('first generation hello', transport_a, function(frame)
			return frame.type == 'hello' and frame.node == 'node-a'
		end)

		conn:retain(topics.cfg(), link_config({
			id = 'link-b',
			peer_id = 'node-c',
		}))

		wait_written('replacement generation hello', transport_b, function(frame)
			return frame.type == 'hello' and frame.node == 'node-a'
		end)

		local ok_closed = probe.wait_until(function()
			return transport_a.closes() >= 1
		end, { timeout = 1.5, interval = 0.002 })
		assert_true(ok_closed, 'old generation transport should be closed after config replacement')
	end, { timeout = 4.0 })
end

function T.fabric_exposes_public_transfer_manager_capability()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local transport = new_line_transport()

		start_public_fabric(scope, conn, link_config({
			id = 'link-a',
			peer_id = 'node-b',
		}), transport)

		local meta = probe.wait_retained_payload(conn, topics.transfer_manager_meta(), {
			timeout = 1.5,
		})
		assert_eq(meta.owner, 'fabric')
		assert_eq(meta.class, 'transfer-manager')
		assert_eq(meta.methods[1], 'send-blob')

		local status = wait_retained_payload_where(conn, topics.transfer_manager_status(), 'fabric transfer manager available', function (p)
			return p and p.available == true
		end, { timeout = 1.5 })
		assert_eq(status.available, true)
		assert_eq(status.links[1], 'link-a')

		local reply, err = conn:call(topics.transfer_manager_rpc('send-blob'), {
			link_id = 'missing-link',
			request_id = 'xfer-missing-link',
			target = 'mcu',
			size = 0,
			digest = protocol.digest_hex(''),
			data = '',
		}, { timeout = 1.0 })
		assert_eq(reply, nil)
		assert_eq(err, 'link_not_ready')
	end, { timeout = 4.0 })
end


function T.fabric_pair_sends_blob_to_registered_remote_transfer_target()
	runfibers.run(function(scope)
		local bus_a = busmod.new()
		local bus_b = busmod.new()
		local conn_a = bus_a:connect()
		local conn_b = bus_b:connect()
		local transport_a = new_line_transport()
		local transport_b = new_line_transport()
		connect_line_transports(transport_a, transport_b)
		trace_transport('node-a transport', transport_a)
		trace_transport('node-b transport', transport_b)
		chat('created paired in-memory line transports')

		local received = {}
		local committed = false
		local target = {}
		function target:open_sink_op(req)
			chat('remote target open_sink_op', req)
			assert_eq(req.target, 'updater/main')
			assert_eq(req.size, 6)
			assert_eq(req.digest, protocol.digest_hex('abcdef'))
			local sink = {}
			function sink:append_op(chunk)
				chat('remote target append_op', { chunk = chunk, received_before = table.concat(received) })
				received[#received + 1] = chunk
				return fibers.always(true, nil)
			end
			function sink:commit_op(req2)
				chat('remote target commit_op', req2)
				committed = true
				return fibers.always({ staged = true, digest = req2.digest }, nil)
			end
			function sink:abort(reason)
				chat('remote target abort', reason)
				return true, nil
			end
			return fibers.always(sink, nil)
		end

		local cfg_a = link_config({
			local_node = 'node-a',
			id = 'link-a',
			peer_id = 'node-b',
			transfer = { chunk_size = 3, timeout_s = 1.0 },
		})
		local cfg_b = link_config({
			local_node = 'node-b',
			id = 'link-a',
			peer_id = 'node-a',
			transfer = { chunk_size = 3, timeout_s = 1.0 },
		})

		chat('starting node-a fabric service')
		start_public_fabric(scope, conn_a, cfg_a, transport_a)
		chat('starting node-b fabric service with receive target updater/main')
		start_public_fabric(scope, conn_b, cfg_b, transport_b, {
			link_overrides = {
				['link-a'] = {
					open_transport_op = function () return wrap_session_op(transport_b.session) end,
					transfer = {
						chunk_size = 3,
						timeout_s = 1.0,
						receive_targets = { ['updater/main'] = target },
					},
				},
			},
		})

		chat('waiting for fabric handshakes')
		chat('saw handshake', wait_written('node-a hello', transport_a, function(frame)
			return frame.type == 'hello' and frame.node == 'node-a'
		end))
		chat('saw handshake', wait_written('node-b hello', transport_b, function(frame)
			return frame.type == 'hello' and frame.node == 'node-b'
		end))
		chat('saw handshake', wait_written('node-a hello_ack', transport_a, function(frame)
			return frame.type == 'hello_ack' and frame.node == 'node-a'
		end))
		chat('saw handshake', wait_written('node-b hello_ack', transport_b, function(frame)
			return frame.type == 'hello_ack' and frame.node == 'node-b'
		end))

		chat('waiting for node-a transfer manager status')
		chat('node-a transfer manager status', wait_retained_payload_where(conn_a, topics.transfer_manager_status(), 'node-a transfer manager available', function (p)
			return p and p.available == true
		end, { timeout = 1.5 }))
		chat('waiting for node-b transfer manager status')
		chat('node-b transfer manager status', wait_retained_payload_where(conn_b, topics.transfer_manager_status(), 'node-b transfer manager available', function (p)
			return p and p.available == true
		end, { timeout = 1.5 }))

		chat('calling node-a transfer manager send-blob')
		local reply, err = conn_a:call(topics.transfer_manager_rpc('send-blob'), {
			link_id = 'link-a',
			request_id = 'xfer-real-fabric',
			xfer_id = 'xfer-real-fabric',
			target = 'updater/main',
			size = 6,
			digest = protocol.digest_hex('abcdef'),
			data = 'abcdef',
			chunk_size = 3,
			timeout_s = 2.0,
			meta = { kind = 'firmware', component = 'mcu' },
		}, { timeout = 2.0 })
		chat('send-blob returned', { reply = reply, err = err, received = table.concat(received), committed = committed })
		if reply == nil then
			dump_transport('node-a transport', transport_a)
			dump_transport('node-b transport', transport_b)
			local status_a = conn_a:retained_view(topics.transfer_manager_status())
			local status_b = conn_b:retained_view(topics.transfer_manager_status())
			local msg_a = status_a:get(topics.transfer_manager_status())
			local msg_b = status_b:get(topics.transfer_manager_status())
			chat('node-a retained transfer status at failure', msg_a and msg_a.payload or nil)
			chat('node-b retained transfer status at failure', msg_b and msg_b.payload or nil)
			status_a:close()
			status_b:close()
		end
		assert(reply ~= nil, tostring(err))
		assert_eq(reply.ok, true)
		assert_eq(table.concat(received), 'abcdef')
		assert_true(committed)
	end, { timeout = 6.0 })
end

return T
