local fibers    = require 'fibers'
local channel   = require 'fibers.channel'
local sleep     = require 'fibers.sleep'
local op        = require 'fibers.op'

local hal_types = require 'services.hal.types.core'
local cap_args  = require 'services.hal.types.capability_args'

local runfibers = require 'tests.support.run_fibers'
local pty       = require 'tests.support.pty'
local safe      = require 'coxpcall'

local perform = fibers.perform
local T = {}

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

local function call_control(cap, verb, opts)
	local reply_ch = channel.new(1)
	local req, err = hal_types.new.ControlRequest(verb, opts or {}, reply_ch)
	assert(req, tostring(err))

	-- channel:put_op() returns no values on success
	perform(cap.control_ch:put_op(req))

	local reply = wait_channel_get(reply_ch, 1.0, 'control reply')
	assert(type(reply) == 'table', 'control reply must be a table')
	assert(type(reply.ok) == 'boolean', 'control reply ok must be boolean')

	return reply
end

local function open_uart_session(cap)
	local open_opts, err = cap_args.new.UARTOpenOpts()
	assert(open_opts, tostring(err))

	local reply = call_control(cap, 'open', open_opts)
	assert(reply.ok == true, tostring(reply.reason))
	assert(type(reply.reason) == 'table')
	assert(type(reply.reason.session) == 'table')
	return reply.reason.session, reply.reason
end

local function start_manager(scope)
	local uart_mgr = fresh_manager()

	local dev_ev_ch   = channel.new(16)
	local cap_emit_ch = channel.new(32)

	local ok, err = perform(uart_mgr.start_op(dummy_logger(), dev_ev_ch, cap_emit_ch))
	assert(ok == true, tostring(err))

	scope:finally(function()
		safe.pcall(function()
			perform(uart_mgr.stop_op())
		end)
	end)

	return uart_mgr, dev_ev_ch, cap_emit_ch
end

function T.devhost_uart_open_returns_wrapped_session_and_allows_reopen()
	runfibers.run(function(scope)
		local uart_mgr, dev_ev_ch = start_manager(scope)
		local port = pty.open(scope)

		local ok_cfg, err_cfg = perform(uart_mgr.apply_config_op({
			{
				id   = 'uart0',
				path = port.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		}))
		assert(ok_cfg == true, tostring(err_cfg))

		local added = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		assert(type(added.capabilities) == 'table' and #added.capabilities == 1)
		local cap = added.capabilities[1]
		assert(cap.class == 'uart')
		assert(cap.id == 'uart0')

		local session1 = open_uart_session(cap)
		local ok_w1, err_w1 = port:write('abc')
		assert(ok_w1 == true, tostring(err_w1))

		local got1, rerr1 = perform(session1:read_some_op(3))
		assert(got1 ~= nil, tostring(rerr1))
		assert(got1 == 'abc', ('expected "abc", got %q'):format(tostring(got1)))

		local n1, swerr1 = perform(session1:write_op('xyz'))
		assert(n1 ~= nil, tostring(swerr1))
		local got2 = port:expect_some(3, 1.0, 'read from PTY master')
		assert(got2 == 'xyz', ('expected "xyz", got %q'):format(tostring(got2)))

		local ok_c1, cerr1 = perform(session1:close_op())
		assert(ok_c1 ~= nil, tostring(cerr1))

		local session2 = open_uart_session(cap)
		local n2, swerr2 = perform(session2:write_op('q'))
		assert(n2 ~= nil, tostring(swerr2))
		local got3 = port:expect_some(1, 1.0, 'read from reopened UART session')
		assert(got3 == 'q', ('expected "q", got %q'):format(tostring(got3)))

		local ok_c2, cerr2 = perform(session2:close_op())
		assert(ok_c2 ~= nil, tostring(cerr2))
	end, { timeout = 4.0 })
end

function T.devhost_uart_reconfigures_when_the_port_changes()
	runfibers.run(function(scope)
		local uart_mgr, dev_ev_ch = start_manager(scope)
		local port1 = pty.open(scope)
		local port2 = pty.open(scope)

		local ok1, err1 = perform(uart_mgr.apply_config_op({
			{
				id   = 'uart0',
				path = port1.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		}))
		assert(ok1 == true, tostring(err1))

		local added1 = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		local cap1 = added1.capabilities[1]
		local session1 = open_uart_session(cap1)

		local n1, errw1 = perform(session1:write_op('first'))
		assert(n1 ~= nil, tostring(errw1))
		local got1 = port1:expect_some(5, 1.0, 'read from first PTY master')
		assert(got1 == 'first', ('expected "first", got %q'):format(tostring(got1)))

		local okc1, cerr1 = perform(session1:close_op())
		assert(okc1 ~= nil, tostring(cerr1))

		local ok2, err2 = perform(uart_mgr.apply_config_op({
			{
				id   = 'uart0',
				path = port2.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		}))
		assert(ok2 == true, tostring(err2))

		local removed = wait_device_event(dev_ev_ch, 'removed', 'uart', 'uart0', 1.5)
		assert(removed ~= nil)
		local added2 = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		local cap2 = added2.capabilities[1]

		local session2 = open_uart_session(cap2)
		local n2, errw2 = perform(session2:write_op('second'))
		assert(n2 ~= nil, tostring(errw2))
		local got2 = port2:expect_some(6, 1.0, 'read from second PTY master')
		assert(got2 == 'second', ('expected "second", got %q'):format(tostring(got2)))

		local okc2, cerr2 = perform(session2:close_op())
		assert(okc2 ~= nil, tostring(cerr2))
	end, { timeout = 4.0 })
end


function T.reconfigure_poisons_old_session_wrapper()
	runfibers.run(function(scope)
		local uart_mgr, dev_ev_ch = start_manager(scope)
		local port1 = pty.open(scope)
		local port2 = pty.open(scope)

		local ok1, err1 = perform(uart_mgr.apply_config_op({
			{
				id   = 'uart0',
				path = port1.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		}))
		assert(ok1 == true, tostring(err1))

		local added1 = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		local cap1 = added1.capabilities[1]
		local session1 = open_uart_session(cap1)

		local n1, errw1 = perform(session1:write_op('old'))
		assert(n1 ~= nil, tostring(errw1))
		local got1 = port1:expect_some(3, 1.0, 'read from old PTY master')
		assert(got1 == 'old', ('expected "old", got %q'):format(tostring(got1)))

		local ok2, err2 = perform(uart_mgr.apply_config_op({
			{
				id   = 'uart0',
				path = port2.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		}))
		assert(ok2 == true, tostring(err2))

		wait_device_event(dev_ev_ch, 'removed', 'uart', 'uart0', 1.5)
		local added2 = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		local cap2 = added2.capabilities[1]

		local old_n, old_werr = perform(session1:write_op('x'))
		assert(old_n == nil)
		assert(old_werr ~= nil)
		local old_chunk, old_rerr = perform(session1:read_some_op(1))
		assert(old_chunk == nil)
		assert(old_rerr ~= nil)

		local session2 = open_uart_session(cap2)
		local n2, errw2 = perform(session2:write_op('new'))
		assert(n2 ~= nil, tostring(errw2))
		local got2 = port2:expect_some(3, 1.0, 'read from new PTY master')
		assert(got2 == 'new', ('expected "new", got %q'):format(tostring(got2)))

		local okc2, cerr2 = perform(session2:close_op())
		assert(okc2 ~= nil, tostring(cerr2))
	end, { timeout = 4.0 })
end

function T.pending_read_loses_to_timeout_cleanly()
	runfibers.run(function(scope)
		local uart_mgr, dev_ev_ch = start_manager(scope)
		local port = pty.open(scope)

		local ok_cfg, err_cfg = perform(uart_mgr.apply_config_op({
			{
				id   = 'uart0',
				path = port.slave_name,
				baud = 115200,
				mode = '8N1',
			},
		}))
		assert(ok_cfg == true, tostring(err_cfg))

		local added = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
		local cap = added.capabilities[1]
		local session = open_uart_session(cap)

		local which = perform(fibers.named_choice{
			data = session:read_some_op(16):wrap(function(chunk, err)
				return 'data', chunk, err
			end),
			timeout = sleep.sleep_op(0.05):wrap(function()
				return 'timeout'
			end),
		})

		assert(which == 'timeout')

		local ok_c, cerr = perform(session:close_op())
		assert(ok_c ~= nil, tostring(cerr))
	end, { timeout = 3.0 })
end

return T
