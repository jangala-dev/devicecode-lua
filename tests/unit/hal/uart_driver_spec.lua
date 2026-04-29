local fibers      = require 'fibers'
local channel     = require 'fibers.channel'
local sleep       = require 'fibers.sleep'

local runfibers   = require 'tests.support.run_fibers'
local pty         = require 'tests.support.pty'

local core_types  = require 'services.hal.types.core'
local cap_args    = require 'services.hal.types.capability_args'

local T = {}

local function fresh_driver()
	package.loaded['services.hal.drivers.uart'] = nil
	return require('services.hal.drivers.uart')
end

local function recv_or_fail(ch)
	local v, err = fibers.perform(ch:get_op())
	assert(v ~= nil, tostring(err))
	return v
end

local function wait_emit(cap_emit_ch, class, id, mode, key, timeout_s)
	local deadline = fibers.now() + (timeout_s or 1.0)

	while fibers.now() < deadline do
		local remain = deadline - fibers.now()
		local which, a = fibers.perform(fibers.named_choice{
			item = cap_emit_ch:get_op(),
			timeout = sleep.sleep_op(remain):wrap(function()
				return 'timeout'
			end),
		})

		if which == 'timeout' then
			break
		end

		local ev = a
		if ev and ev.class == class and ev.id == id and ev.mode == mode and ev.key == key then
			return ev
		end
	end

	error(('timed out waiting for %s/%s %s %s'):format(
		tostring(class), tostring(id), tostring(mode), tostring(key)
	), 0)
end

local function call_control_op(control_ch, verb, opts)
	return fibers.run_scope_op(function()
		local reply_ch = channel.new(1)

		local req, err = core_types.new.ControlRequest(verb, opts or {}, reply_ch)
		assert(req, tostring(err))

		-- channel:put_op() returns no values on success; success is "no error raised"
		fibers.perform(control_ch:put_op(req))

		local reply, recv_err = fibers.perform(reply_ch:get_op())
		if not reply then
			return false, tostring(recv_err or 'missing reply')
		end

		assert(type(reply) == 'table', 'control reply must be a table')
		assert(type(reply.ok) == 'boolean', 'control reply ok must be boolean')

		if reply.ok then
			return true, reply.reason
		end

		return false, reply.reason
	end):wrap(function(st, rep, ok, value_or_err)
		if st ~= 'ok' then
			return false, tostring(value_or_err or rep)
		end
		return ok, value_or_err
	end)
end

local function drain_initial_emits(cap_emit_ch, id)
	local e1 = recv_or_fail(cap_emit_ch)
	local e2 = recv_or_fail(cap_emit_ch)

	local by_mode = {
		[e1.mode] = e1,
		[e2.mode] = e2,
	}

	assert(by_mode.meta ~= nil)
	assert(by_mode.state ~= nil)
	assert(by_mode.meta.class == 'uart')
	assert(by_mode.meta.id == id)
	assert(by_mode.meta.key == 'details')
	assert(by_mode.state.class == 'uart')
	assert(by_mode.state.id == id)
	assert(by_mode.state.key == 'status')

	return by_mode
end

function T.capabilities_op_returns_one_uart_capability()
	local uart = fresh_driver()

	runfibers.run(function()
		local emit_ch = channel.new(8)
		local d = uart.new('mcu', '/dev/null', 115200, '8N1', nil)

		local ok, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok == true, tostring(caps_or_err))
		assert(type(caps_or_err) == 'table' and #caps_or_err == 1)

		local cap = caps_or_err[1]
		assert(cap.class == 'uart')
		assert(cap.id == 'mcu')
		assert(cap.offerings.open == true)
		assert(cap.offerings.status == true)
		assert(cap.offerings.close == nil)
		assert(cap.offerings.write == nil)
	end)
end

function T.start_op_emits_initial_meta_and_status()
	local uart = fresh_driver()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local emit_ch = channel.new(8)

		local d = uart.new('mcu', port.slave_name, 115200, '8N1', nil)
		local ok_caps, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_or_err))

		local ok_start, err_start = fibers.perform(d:start_op(scope))
		assert(ok_start == true, tostring(err_start))

		local initial = drain_initial_emits(emit_ch, 'mcu')
		assert(initial.meta.data.path == port.slave_name)
		assert(initial.meta.data.kind == 'uart')
		assert(initial.state.data.open == false)
		assert(initial.state.data.available == true)

		local ok_stop, err_stop = fibers.perform(d:stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.status_reports_open_false_before_any_session_exists()
	local uart = fresh_driver()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local emit_ch = channel.new(8)

		local d = uart.new('mcu', port.slave_name, 115200, '8N1', nil)
		local ok_caps, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_or_err))

		local ok_start, err_start = fibers.perform(d:start_op(scope))
		assert(ok_start == true, tostring(err_start))

		drain_initial_emits(emit_ch, 'mcu')

		local ok, status = fibers.perform(call_control_op(d.control_ch, 'status', {}))
		assert(ok == true, tostring(status))
		assert(type(status) == 'table')
		assert(status.open == false)
		assert(status.available == true)
		assert(status.path == port.slave_name)

		local ok_stop, err_stop = fibers.perform(d:stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.open_returns_uart_open_reply_with_wrapped_session()
	local uart = fresh_driver()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local emit_ch = channel.new(16)

		local d = uart.new('mcu', port.slave_name, 115200, '8N1', nil)

		local ok_caps, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_or_err))

		local ok_start, err_start = fibers.perform(d:start_op(scope))
		assert(ok_start == true, tostring(err_start))

		drain_initial_emits(emit_ch, 'mcu')

		local opts, opts_err = cap_args.new.UARTOpenOpts()
		assert(opts, tostring(opts_err))

		local ok, reply = fibers.perform(call_control_op(d.control_ch, 'open', opts))
		assert(ok == true, tostring(reply))
		assert(type(reply) == 'table')
		assert(type(reply.lease_id) == 'string' and reply.lease_id ~= '')
		assert(reply.path == port.slave_name)
		assert(type(reply.session) == 'table')
		assert(type(reply.session.read_some_op) == 'function')
		assert(type(reply.session.read_exactly_op) == 'function')
		assert(type(reply.session.read_line_op) == 'function')
		assert(type(reply.session.read_all_op) == 'function')
		assert(type(reply.session.write_op) == 'function')
		assert(type(reply.session.flush_op) == 'function')
		assert(type(reply.session.close_op) == 'function')

		local st = wait_emit(emit_ch, 'uart', 'mcu', 'state', 'status', 1.0)
		assert(st.data.open == true)
		assert(st.data.lease_id == reply.lease_id)

		local ev = wait_emit(emit_ch, 'uart', 'mcu', 'event', 'opened', 1.0)
		assert(ev.data.lease_id == reply.lease_id)

		local ok_close, err_close = fibers.perform(reply.session:close_op())
		assert(ok_close == true, tostring(err_close))

		local st2 = wait_emit(emit_ch, 'uart', 'mcu', 'state', 'status', 1.0)
		assert(st2.data.open == false)
		assert(st2.data.lease_id == nil)

		local ev2 = wait_emit(emit_ch, 'uart', 'mcu', 'event', 'closed', 1.0)
		assert(ev2.data.lease_id == reply.lease_id)

		local ok_stop, err_stop = fibers.perform(d:stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.second_open_while_active_returns_busy()
	local uart = fresh_driver()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local emit_ch = channel.new(16)

		local d = uart.new('mcu', port.slave_name, 115200, '8N1', nil)

		local ok_caps, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_or_err))

		local ok_start, err_start = fibers.perform(d:start_op(scope))
		assert(ok_start == true, tostring(err_start))

		drain_initial_emits(emit_ch, 'mcu')

		local opts = assert(cap_args.new.UARTOpenOpts())
		local ok1, reply1 = fibers.perform(call_control_op(d.control_ch, 'open', opts))
		assert(ok1 == true, tostring(reply1))
		wait_emit(emit_ch, 'uart', 'mcu', 'state', 'status', 1.0)
		wait_emit(emit_ch, 'uart', 'mcu', 'event', 'opened', 1.0)

		local ok2, err2 = fibers.perform(call_control_op(d.control_ch, 'open', opts))
		assert(ok2 == false)
		assert(type(err2) == 'string')
		assert(err2:match('busy'))

		local ok_close, err_close = fibers.perform(reply1.session:close_op())
		assert(ok_close == true, tostring(err_close))
		wait_emit(emit_ch, 'uart', 'mcu', 'state', 'status', 1.0)
		wait_emit(emit_ch, 'uart', 'mcu', 'event', 'closed', 1.0)

		local ok_stop, err_stop = fibers.perform(d:stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.stop_op_closes_active_session_best_effort()
	local uart = fresh_driver()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local emit_ch = channel.new(16)

		local d = uart.new('mcu', port.slave_name, 115200, '8N1', nil)

		local ok_caps, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_or_err))

		local ok_start, err_start = fibers.perform(d:start_op(scope))
		assert(ok_start == true, tostring(err_start))

		drain_initial_emits(emit_ch, 'mcu')

		local opts = assert(cap_args.new.UARTOpenOpts())
		local ok, reply = fibers.perform(call_control_op(d.control_ch, 'open', opts))
		assert(ok == true, tostring(reply))
		wait_emit(emit_ch, 'uart', 'mcu', 'state', 'status', 1.0)
		wait_emit(emit_ch, 'uart', 'mcu', 'event', 'opened', 1.0)

		local ok_stop, err_stop = fibers.perform(d:stop_op())
		assert(ok_stop == true, tostring(err_stop))

		local n, werr = fibers.perform(reply.session:write_op('x'))
		assert(n == nil)
		assert(werr ~= nil)
	end)
end


function T.read_ops_fail_after_stop()
	local uart = fresh_driver()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local emit_ch = channel.new(16)

		local d = uart.new('mcu', port.slave_name, 115200, '8N1', nil)

		local ok_caps, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_or_err))

		local ok_start, err_start = fibers.perform(d:start_op(scope))
		assert(ok_start == true, tostring(err_start))

		drain_initial_emits(emit_ch, 'mcu')

		local opts = assert(cap_args.new.UARTOpenOpts())
		local ok, reply = fibers.perform(call_control_op(d.control_ch, 'open', opts))
		assert(ok == true, tostring(reply))
		wait_emit(emit_ch, 'uart', 'mcu', 'state', 'status', 1.0)
		wait_emit(emit_ch, 'uart', 'mcu', 'event', 'opened', 1.0)

		local ok_stop, err_stop = fibers.perform(d:stop_op())
		assert(ok_stop == true, tostring(err_stop))

		local chunk, rerr = fibers.perform(reply.session:read_some_op(1))
		assert(chunk == nil)
		assert(rerr ~= nil)

		local n, werr = fibers.perform(reply.session:write_op('x'))
		assert(n == nil)
		assert(werr ~= nil)
	end)
end

function T.concurrent_open_allows_exactly_one_winner()
	local uart = fresh_driver()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local emit_ch = channel.new(16)
		local results_ch = channel.new(2)

		local d = uart.new('mcu', port.slave_name, 115200, '8N1', nil)
		local ok_caps, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_or_err))
		local ok_start, err_start = fibers.perform(d:start_op(scope))
		assert(ok_start == true, tostring(err_start))
		drain_initial_emits(emit_ch, 'mcu')

		local opts = assert(cap_args.new.UARTOpenOpts())
		local function contender(name)
			local ok, value = fibers.perform(call_control_op(d.control_ch, 'open', opts))
			fibers.perform(results_ch:put_op({ name = name, ok = ok, value = value }))
		end

		local s1, e1 = scope:spawn(function() contender('a') end)
		assert(s1 == true, tostring(e1))
		local s2, e2 = scope:spawn(function() contender('b') end)
		assert(s2 == true, tostring(e2))

		local r1 = recv_or_fail(results_ch)
		local r2 = recv_or_fail(results_ch)
		local results = { r1, r2 }
		local winners, losers = {}, {}
		for _, r in ipairs(results) do
			if r.ok then winners[#winners + 1] = r else losers[#losers + 1] = r end
		end
		assert(#winners == 1)
		assert(#losers == 1)
		assert(type(losers[1].value) == 'string' and losers[1].value:match('busy'))

		local st = wait_emit(emit_ch, 'uart', 'mcu', 'state', 'status', 1.0)
		assert(st.data.open == true)
		assert(st.data.lease_id == winners[1].value.lease_id)
		local ev = wait_emit(emit_ch, 'uart', 'mcu', 'event', 'opened', 1.0)
		assert(ev.data.lease_id == winners[1].value.lease_id)

		local ok_close, err_close = fibers.perform(winners[1].value.session:close_op())
		assert(ok_close == true, tostring(err_close))
		wait_emit(emit_ch, 'uart', 'mcu', 'state', 'status', 1.0)
		wait_emit(emit_ch, 'uart', 'mcu', 'event', 'closed', 1.0)

		local ok_stop, err_stop = fibers.perform(d:stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.open_rejects_invalid_opts()
	local uart = fresh_driver()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local emit_ch = channel.new(8)

		local d = uart.new('mcu', port.slave_name, 115200, '8N1', nil)

		local ok_caps, caps_or_err = fibers.perform(d:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_or_err))

		local ok_start, err_start = fibers.perform(d:start_op(scope))
		assert(ok_start == true, tostring(err_start))

		drain_initial_emits(emit_ch, 'mcu')

		local ok, err = fibers.perform(call_control_op(d.control_ch, 'open', { bogus = true }))
		assert(ok == false)
		assert(type(err) == 'string')
		assert(err:match('invalid open opts') or err:match('unsupported'))

		local ok_stop, err_stop = fibers.perform(d:stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

return T
