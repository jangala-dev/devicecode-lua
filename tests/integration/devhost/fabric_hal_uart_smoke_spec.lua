-- tests/integration/devhost/fabric_hal_uart_smoke_spec.lua
--
-- Devhost smoke test for Fabric over the real HAL UART manager/driver path.
--
-- This deliberately follows integration.devhost.hal_uart_spec for the UART
-- manager setup.  The only extra layer is a small in-test raw-host bus adapter
-- that exposes the emitted manager capability at the endpoint Fabric already
-- knows how to call:
--
--   raw/host/<source>/cap/uart/<id>/rpc/open
--
-- This keeps the smoke test narrow:
--
--   fabric.start -> raw-host bus call -> real HAL UART session -> PTY hello
--
-- It does not try to test the full HAL service config/publication path.

local busmod    = require 'bus'
local fibers    = require 'fibers'
local channel   = require 'fibers.channel'
local sleep     = require 'fibers.sleep'
local op        = require 'fibers.op'
local safe      = require 'coxpcall'

local hal_types = require 'services.hal.types.core'
local cap_args  = require 'services.hal.types.capability_args'

local runfibers = require 'tests.support.run_fibers'
local pty       = require 'tests.support.pty'

local fabric    = require 'services.fabric'
local protocol  = require 'services.fabric.protocol'
local hal_transport = require 'services.fabric.hal_transport'

local perform = fibers.perform
local T = {}

local function assert_eq(a, b, msg)
	assert(a == b, msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
end

local function fresh_manager()
	package.loaded['services.hal.managers.uart'] = nil
	package.loaded['services.hal.drivers.uart'] = nil
	return require('services.hal.managers.uart')
end

local function dummy_logger()
	local logger = {}
	for _, k in ipairs({ 'debug', 'info', 'warn', 'error' }) do
		logger[k] = function() end
	end
	function logger:child()
		return self
	end
	return logger
end

local function wait_channel_get(ch, timeout_s, what)
	local which, a, b = perform(op.named_choice({
		item = ch:get_op(),
		timeout = sleep.sleep_op(timeout_s or 1.0):wrap(function()
			return true
		end),
	}))

	if which == 'timeout' then
		error(('timed out waiting for %s'):format(what or 'channel item'), 0)
	end

	if a == nil then
		error(('channel closed while waiting for %s: %s'):format(what or 'channel item', tostring(b)), 0)
	end

	return a
end

local function wait_device_event(dev_ev_ch, event_type, class, id, timeout_s)
	local deadline = fibers.now() + (timeout_s or 1.0)

	while fibers.now() < deadline do
		local ev = wait_channel_get(dev_ev_ch, deadline - fibers.now(), 'device event')
		if ev.event_type == event_type and ev.class == class and ev.id == id then
			return ev
		end
	end

	error(('timed out waiting for device event %s %s/%s'):format(
		tostring(event_type), tostring(class), tostring(id)
	), 0)
end

local function start_manager(scope)
	local uart_mgr = fresh_manager()

	local dev_ev_ch   = channel.new(16)
	local cap_emit_ch = channel.new(32)

	local ok, err = perform(uart_mgr.start_op(dummy_logger(), dev_ev_ch, cap_emit_ch))
	assert(ok == true, tostring(err))

	-- This mirrors the existing devhost UART tests.  The UART manager currently
	-- exposes only an Op-based stop path, so the test follows the established
	-- integration-test cleanup style rather than pretending this is a Fabric
	-- service finaliser pattern.
	scope:finally(function()
		safe.pcall(function()
			perform(uart_mgr.shutdown_op())
		end)
	end)

	return uart_mgr, dev_ev_ch, cap_emit_ch
end

local function apply_uart_config(uart_mgr, port)
	local ok_cfg, err_cfg = perform(uart_mgr.apply_config_op({
		{
			id   = 'uart0',
			path = port.slave_name,
			baud = 115200,
			mode = '8N1',
		},
	}))
	assert(ok_cfg == true, tostring(err_cfg))
end

local function wait_uart_cap(dev_ev_ch)
	local added = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
	assert(type(added.capabilities) == 'table' and #added.capabilities == 1)
	local cap = added.capabilities[1]
	assert(cap.class == 'uart')
	assert(cap.id == 'uart0')
	assert(type(cap.control_ch) == 'table', 'UART capability should expose control_ch')
	return cap
end

local function normalise_uart_open_opts(opts)
	if opts == nil or getmetatable(opts) ~= cap_args.UARTOpenOpts then
		local open_opts, err = cap_args.new.UARTOpenOpts(opts)
		assert(open_opts, tostring(err))
		return open_opts
	end
	return opts
end

local function call_hal_control(cap, verb, opts)
	local reply_ch = channel.new(1)
	local req, err = hal_types.new.ControlRequest(verb, opts or {}, reply_ch)
	assert(req, tostring(err))

	perform(cap.control_ch:put_op(req))

	local reply = wait_channel_get(reply_ch, 1.0, 'HAL control reply')
	assert(type(reply) == 'table', 'HAL control reply must be a table')
	assert(type(reply.ok) == 'boolean', 'HAL control reply ok must be boolean')

	return reply
end

local function expose_raw_host_uart_open(scope, conn, cap, source)
	source = source or 'uart_manager'

	local ep = conn:bind({ 'raw', 'host', source, 'cap', 'uart', cap.id, 'rpc', 'open' }, {
		queue_len = 4,
	})

	local ok_spawn, spawn_err = scope:spawn(function()
		while true do
			local req = ep:recv()
			if req == nil then
				return
			end

			local open_opts = normalise_uart_open_opts(req.payload)
			local reply = call_hal_control(cap, 'open', open_opts)

			local replied = req:reply(reply)
			if not replied then
				-- The Fabric side may have timed out or been cancelled.  The HAL
				-- session returned by a successful open is owned by that reply path
				-- only if the reply is accepted; close it immediately otherwise.
				if reply.ok == true
					and type(reply.reason) == 'table'
					and type(reply.reason.session) == 'table'
					and type(reply.reason.session.terminate) == 'function'
				then
					reply.reason.session:terminate('fabric request abandoned')
				end
			end
		end
	end)
	assert(ok_spawn, tostring(spawn_err))

	scope:finally(function()
		safe.pcall(function()
			ep:unbind()
		end)
	end)

	return {
		source = source,
		class  = 'uart',
		id     = cap.id,
	}
end

local function fabric_uart_config(raw_cap)
	return {
		schema = fabric.config.SCHEMA,
		local_node = 'devhost-node',
		links = {
			{
				id = 'uart-link',
				peer_id = 'peer-node',
				transport = {
					source = raw_cap.source,
					class  = raw_cap.class,
					id     = raw_cap.id,
				},
				session = {
					hello_interval_s = 0.10,
					ping_interval_s = 5.0,
					liveness_timeout_s = 5.0,
				},
				bridge = {},
			},
		},
	}
end

local function wait_decoded_line(port, timeout_s, label)
	local deadline = fibers.now() + (timeout_s or 2.0)
	local buf = ''

	while fibers.now() < deadline do
		local remain = deadline - fibers.now()
		local which, chunk, err = perform(op.named_choice{
			data = port.master:read_some_op(4096),
			timeout = sleep.sleep_op(remain),
		})

		if which == 'timeout' then
			break
		end

		if chunk == nil and err ~= nil then
			error(('PTY read failed while waiting for %s: %s'):format(
				tostring(label or 'Fabric frame'),
				tostring(err)
			), 0)
		end

		if chunk ~= nil then
			buf = buf .. chunk
			while true do
				local line, rest = buf:match('^(.-)\n(.*)$')
				if not line then break end
				buf = rest

				if line ~= '' then
					local frame, derr = protocol.decode_line(line)
					if frame then
						return frame
					end
					error(('invalid Fabric line while waiting for %s: %s; line=%q'):format(
						tostring(label or 'frame'),
						tostring(derr),
						tostring(line)
					), 0)
				end
			end
		end
	end

	error(('timed out waiting for %s; buffered=%q'):format(
		tostring(label or 'Fabric frame'),
		buf
	), 0)
end

function T.fabric_start_opens_real_hal_uart_manager_session_and_writes_hello()
	runfibers.run(function(scope)
		local uart_mgr, dev_ev_ch = start_manager(scope)
		local port = pty.open(scope)

		apply_uart_config(uart_mgr, port)
		local cap = wait_uart_cap(dev_ev_ch)

		local bus = busmod.new()
		local raw_cap = expose_raw_host_uart_open(scope, bus:connect(), cap, 'uart_manager')

		local ok_fabric, fabric_err = scope:spawn(function()
			local fabric_conn = bus:connect()
			fabric.start(fabric_conn, {
				name = 'fabric',
				env = 'test',
				config = fabric_uart_config(raw_cap),
				link_overrides = {
					['uart-link'] = {
						open_transport_op = function ()
							return hal_transport.open_transport_op(fabric_conn, raw_cap)
						end,
					},
				},
			})
		end)
		assert(ok_fabric, tostring(fabric_err))

		local frame = wait_decoded_line(port, 2.0, 'Fabric hello on HAL UART PTY')
		assert_eq(frame.type, 'hello')
		assert_eq(frame.node, 'devhost-node')
		assert(type(frame.sid) == 'string' and frame.sid ~= '', 'hello should include a sid')
	end, { timeout = 5.0 })
end

return T
