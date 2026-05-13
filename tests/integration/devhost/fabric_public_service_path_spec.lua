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

return T
