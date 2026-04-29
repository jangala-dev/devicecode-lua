local fibers     = require 'fibers'
local channel    = require 'fibers.channel'

local runfibers  = require 'tests.support.run_fibers'
local pty        = require 'tests.support.pty'

local T = {}

local function fresh_manager()
	package.loaded['services.hal.managers.uart'] = nil
	package.loaded['services.hal.drivers.uart'] = nil
	return require('services.hal.managers.uart')
end

local function recv_or_fail(ch)
	local v, err = fibers.perform(ch:get_op())
	assert(v ~= nil, tostring(err))
	return v
end

function T.start_op_and_stop_op_round_trip()
	local M = fresh_manager()

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.apply_config_op_before_start_fails()
	local M = fresh_manager()

	runfibers.run(function()
		local ok, err = fibers.perform(M.apply_config_op({
			{ id = 'mcu', path = '/dev/ttyS0', baud = 115200, mode = '8N1' },
		}))
		assert(ok == false)
		assert(tostring(err):match('not started'))
	end)
end

function T.apply_config_op_adds_uart_driver_and_emits_added_event()
	local M = fresh_manager()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(16)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local ok_cfg, err_cfg = fibers.perform(M.apply_config_op({
			{ id = 'mcu', path = port.slave_name, baud = 115200, mode = '8N1' },
		}))
		assert(ok_cfg == true, tostring(err_cfg))

		local ev = recv_or_fail(dev_ev_ch)
		assert(ev.event_type == 'added')
		assert(ev.class == 'uart')
		assert(ev.id == 'mcu')
		assert(type(ev.capabilities) == 'table' and #ev.capabilities == 1)
		assert(ev.capabilities[1].class == 'uart')
		assert(ev.meta.path == port.slave_name)

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.reapply_same_config_is_idempotent()
	local M = fresh_manager()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(16)

		assert(fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch)) == true)

		local cfg = {
			{ id = 'mcu', path = port.slave_name, baud = 115200, mode = '8N1' },
		}

		local ok1, err1 = fibers.perform(M.apply_config_op(cfg))
		assert(ok1 == true, tostring(err1))
		local added = recv_or_fail(dev_ev_ch)
		assert(added.event_type == 'added')

		local ok2, err2 = fibers.perform(M.apply_config_op(cfg))
		assert(ok2 == true, tostring(err2))

		local which = fibers.perform(require('fibers').named_choice{
			msg = dev_ev_ch:get_op():wrap(function(v) return 'msg', v end),
			timeout = require('fibers.sleep').sleep_op(0.05):wrap(function() return 'timeout' end),
		})
		assert(which == 'timeout')

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.changing_path_causes_removed_then_added()
	local M = fresh_manager()

	runfibers.run(function(scope)
		local port1 = pty.open(scope)
		local port2 = pty.open(scope)
		local dev_ev_ch = channel.new(16)
		local cap_emit_ch = channel.new(16)

		assert(fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch)) == true)

		local ok1, err1 = fibers.perform(M.apply_config_op({
			{ id = 'mcu', path = port1.slave_name, baud = 115200, mode = '8N1' },
		}))
		assert(ok1 == true, tostring(err1))
		assert(recv_or_fail(dev_ev_ch).event_type == 'added')

		local ok2, err2 = fibers.perform(M.apply_config_op({
			{ id = 'mcu', path = port2.slave_name, baud = 115200, mode = '8N1' },
		}))
		assert(ok2 == true, tostring(err2))

		local ev1 = recv_or_fail(dev_ev_ch)
		local ev2 = recv_or_fail(dev_ev_ch)
		assert(ev1.event_type == 'removed')
		assert(ev2.event_type == 'added')
		assert(ev2.id == 'mcu')

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.changing_baud_or_mode_causes_removed_then_added()
	local M = fresh_manager()

	runfibers.run(function(scope)
		local port = pty.open(scope)
		local dev_ev_ch = channel.new(16)
		local cap_emit_ch = channel.new(16)

		assert(fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch)) == true)

		local ok1, err1 = fibers.perform(M.apply_config_op({
			{ id = 'mcu', path = port.slave_name, baud = 115200, mode = '8N1' },
		}))
		assert(ok1 == true, tostring(err1))
		assert(recv_or_fail(dev_ev_ch).event_type == 'added')

		local ok2, err2 = fibers.perform(M.apply_config_op({
			{ id = 'mcu', path = port.slave_name, baud = 9600, mode = '8N1' },
		}))
		assert(ok2 == true, tostring(err2))

		local ev1 = recv_or_fail(dev_ev_ch)
		local ev2 = recv_or_fail(dev_ev_ch)
		assert(ev1.event_type == 'removed')
		assert(ev2.event_type == 'added')

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.fault_op_is_inert_before_start()
	local M = fresh_manager()

	runfibers.run(function()
		local which = fibers.perform(fibers.named_choice{
			fault = M.fault_op():wrap(function(...) return 'fault', ... end),
			timeout = require('fibers.sleep').sleep_op(0.05):wrap(function() return 'timeout' end),
		})
		assert(which == 'timeout')
	end)
end

return T
