-- tests/integration/devhost/hal_uart_spec.lua

local fibers    = require 'fibers'
local channel   = require 'fibers.channel'
local sleep     = require 'fibers.sleep'
local op        = require 'fibers.op'

local hal_types = require 'services.hal.types.core'
local cap_args  = require 'services.hal.types.capability_args'
local uart_mgr  = require 'services.hal.managers.uart'

local runfibers = require 'tests.support.run_fibers'
local pty       = require 'tests.support.pty'

local perform = fibers.perform

local T = {}

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

local function control_call(cap, verb, opts)
	local reply_ch = channel.new(1)
	local req, err = hal_types.new.ControlRequest(verb, opts or {}, reply_ch)
	assert(req, tostring(err))

	cap.control_ch:put(req)

	local reply = wait_channel_get(reply_ch, 1.0, 'control reply')
	assert(reply.ok == true, tostring(reply.reason))
	return reply
end

local function start_manager(scope)
	local dev_ev_ch   = channel.new(16)
	local cap_emit_ch = channel.new(16)

	local start_err = uart_mgr.start(dummy_logger(), dev_ev_ch, cap_emit_ch)
	assert(start_err == '', tostring(start_err))

	scope:finally(function()
		pcall(function()
			uart_mgr.stop()
		end)
	end)

	return dev_ev_ch, cap_emit_ch
end

local function apply_uart_config(serial_ports)
	local ok, err = uart_mgr.apply_config({
		serial_ports = serial_ports,
	})
	assert(ok == true, tostring(err))
end

local function open_uart_stream(cap)
	local open_opts, err = cap_args.new.UARTOpenOpts(true, true)
	assert(open_opts, tostring(err))

	local reply = control_call(cap, 'open', open_opts)
	assert(type(reply.reason) == 'table', 'expected open to return a Stream in Reply.reason')

	local stream = reply.reason
	stream:setvbuf('no')
	return stream
end

function T.devhost_hal_uart_open_returns_real_stream_and_allows_reopen()
	runfibers.run(function(scope)
		local dev_ev_ch = start_manager(scope)
		local port = pty.open(scope)

		apply_uart_config({
			{
				name = 'uart0',
				path = port.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		})

		local added = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		assert(type(added.capabilities) == 'table' and #added.capabilities == 1, 'expected one uart capability')
		local cap = added.capabilities[1]
		assert(cap.class == 'uart')
		assert(cap.id == 'uart0')

		local stream1 = open_uart_stream(cap)

		local ok_w1, err_w1 = port:write('abc')
		assert(ok_w1 == true, tostring(err_w1))
		local got1 = pty.expect_some(stream1, 3, 1.0, 'read from UART stream')
		assert(got1 == 'abc', ('expected "abc", got %q'):format(tostring(got1)))

		local n1, swerr1 = perform(stream1:write_op('xyz'))
		assert(n1 ~= nil, tostring(swerr1))
		local got2 = port:expect_some(3, 1.0, 'read from PTY master')
		assert(got2 == 'xyz', ('expected "xyz", got %q'):format(tostring(got2)))

		local ok_c1, cerr1 = perform(stream1:close_op())
		assert(ok_c1 ~= nil, tostring(cerr1))

		local stream2 = open_uart_stream(cap)
		local n2, swerr2 = perform(stream2:write_op('q'))
		assert(n2 ~= nil, tostring(swerr2))
		local got3 = port:expect_some(1, 1.0, 'read from reopened UART stream')
		assert(got3 == 'q', ('expected "q", got %q'):format(tostring(got3)))

		local ok_c2, cerr2 = perform(stream2:close_op())
		assert(ok_c2 ~= nil, tostring(cerr2))
	end, { timeout = 4.0 })
end

function T.devhost_hal_uart_reconfigures_when_the_port_changes()
	runfibers.run(function(scope)
		local dev_ev_ch = start_manager(scope)
		local port1 = pty.open(scope)
		local port2 = pty.open(scope)

		apply_uart_config({
			{
				name = 'uart0',
				path = port1.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		})

		local added1 = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		local cap1 = added1.capabilities[1]
		local stream1 = open_uart_stream(cap1)

		local n1, err1 = perform(stream1:write_op('first'))
		assert(n1 ~= nil, tostring(err1))
		local got1 = port1:expect_some(5, 1.0, 'read from first PTY master')
		assert(got1 == 'first', ('expected "first", got %q'):format(tostring(got1)))

		local ok_c1, cerr1 = perform(stream1:close_op())
		assert(ok_c1 ~= nil, tostring(cerr1))

		apply_uart_config({
			{
				name = 'uart0',
				path = port2.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		})

		wait_device_event(dev_ev_ch, 'removed', 'uart', 'uart0', 1.5)
		local added2 = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		local cap2 = added2.capabilities[1]
		local stream2 = open_uart_stream(cap2)

		local n2, err2 = perform(stream2:write_op('second'))
		assert(n2 ~= nil, tostring(err2))

		local got2 = port2:expect_some(6, 1.0, 'read from second PTY master')
		assert(got2 == 'second', ('expected "second", got %q'):format(tostring(got2)))

		-- The old port should now be quiet or closed, but it must not receive the new bytes.
		port1:expect_no_data(0.15, 'old PTY master after reconfigure')

		local ok_c2, cerr2 = perform(stream2:close_op())
		assert(ok_c2 ~= nil, tostring(cerr2))
	end, { timeout = 4.5 })
end

return T
