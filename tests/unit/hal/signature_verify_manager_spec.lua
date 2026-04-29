local fibers     = require 'fibers'
local sleep      = require 'fibers.sleep'
local channel    = require 'fibers.channel'

local runfibers  = require 'tests.support.run_fibers'

local T = {}

local function fresh_manager()
	package.loaded['services.hal.managers.signature_verify'] = nil
	return require 'services.hal.managers.signature_verify'
end

local function recv_or_fail(ch)
	local v, err = fibers.perform(ch:get_op())
	assert(v, tostring(err))
	return v
end

local function fake_backend(name, ok, value_or_err)
	return {
		backend_name = name or 'fake-manager-backend',

		verify_ed25519_op = function()
			return require('fibers').always(ok, value_or_err)
		end,
	}
end

function T.apply_config_fails_when_not_started()
	local M = fresh_manager()

	runfibers.run(function()
		local ok, err = fibers.perform(M.apply_config_op({
			providers = {
				{ id = 'main', backend = fake_backend('fake-a', true, nil) },
			},
		}))
		assert(ok == false)
		assert(tostring(err):match('not started'))
	end)
end

function T.start_apply_config_and_stop_round_trip()
	local M = fresh_manager()

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local ok_cfg, err_cfg = fibers.perform(M.apply_config_op({
			providers = {
				{
					id = 'main',
					backend = fake_backend('fake-sig-manager', true, { verified = true }),
					max_in_flight = 2,
				},
			},
		}))
		assert(ok_cfg == true, tostring(err_cfg))

		local ev = recv_or_fail(dev_ev_ch)
		assert(ev.event_type == 'added')
		assert(ev.class == 'signature_verify')
		assert(ev.id == 'main')
		assert(#ev.capabilities == 1)
		assert(ev.capabilities[1].class == 'signature_verify')
		assert(ev.capabilities[1].offerings.verify_ed25519 == true)

		local e1 = recv_or_fail(cap_emit_ch)
		local e2 = recv_or_fail(cap_emit_ch)

		local by_mode = {
			[e1.mode] = e1,
			[e2.mode] = e2,
		}

		assert(by_mode.meta ~= nil)
		assert(by_mode.state ~= nil)
		assert(by_mode.meta.class == 'signature_verify')
		assert(by_mode.meta.id == 'main')
		assert(by_mode.meta.key == 'info')
		assert(by_mode.meta.data.backend == 'fake-sig-manager')
		assert(by_mode.meta.data.max_in_flight == 2)
		assert(by_mode.state.key == 'status')
		assert(by_mode.state.data.state == 'available')

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.reapply_same_config_is_idempotent()
	local M = fresh_manager()
	local backend = fake_backend('same-backend', true, nil)

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local cfg = {
			providers = {
				{
					id = 'main',
					backend = backend,
					max_in_flight = 1,
				},
			},
		}

		local ok1, err1 = fibers.perform(M.apply_config_op(cfg))
		assert(ok1 == true, tostring(err1))
		local added = recv_or_fail(dev_ev_ch)
		assert(added.event_type == 'added')

		local ok2, err2 = fibers.perform(M.apply_config_op(cfg))
		assert(ok2 == true, tostring(err2))

		local which = fibers.perform(require('fibers').named_choice{
			msg = dev_ev_ch:get_op():wrap(function(v) return 'msg', v end),
			timeout = sleep.sleep_op(0.05):wrap(function() return 'timeout' end),
		})
		assert(which == 'timeout', 'reapplying same config should not emit new device events')

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.config_change_removes_then_adds_provider()
	local M = fresh_manager()
	local backend = fake_backend('change-backend', true, nil)

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local ok1, err1 = fibers.perform(M.apply_config_op({
			providers = {
				{
					id = 'main',
					backend = backend,
					max_in_flight = 1,
				},
			},
		}))
		assert(ok1 == true, tostring(err1))
		local first = recv_or_fail(dev_ev_ch)
		assert(first.event_type == 'added')

		local ok2, err2 = fibers.perform(M.apply_config_op({
			providers = {
				{
					id = 'main',
					backend = backend,
					max_in_flight = 2,
				},
			},
		}))
		assert(ok2 == true, tostring(err2))

		local ev_a = recv_or_fail(dev_ev_ch)
		local ev_b = recv_or_fail(dev_ev_ch)
		assert(ev_a.event_type == 'removed')
		assert(ev_b.event_type == 'added')
		assert(ev_b.id == 'main')

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.invalid_config_is_rejected()
	local M = fresh_manager()

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local ok_cfg, err_cfg = fibers.perform(M.apply_config_op({
			providers = 'nope',
		}))
		assert(ok_cfg == false)
		assert(tostring(err_cfg):match('providers must be a table'))

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)
end

function T.stop_op_before_start_is_ok_and_fault_op_is_inert()
	local M = fresh_manager()

	runfibers.run(function()
		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))

		local which = fibers.perform(require('fibers').named_choice{
			fault = M.fault_op():wrap(function(...) return 'fault', ... end),
			timeout = sleep.sleep_op(0.05):wrap(function() return 'timeout' end),
		})
		assert(which == 'timeout')
	end)
end

return T
