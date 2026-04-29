local fibers    = require 'fibers'
local sleep     = require 'fibers.sleep'
local channel   = require 'fibers.channel'

local runfibers = require 'tests.support.run_fibers'

local T = {}

local function fresh_manager()
	package.loaded['services.hal.managers.artifact_store'] = nil
	return require 'services.hal.managers.artifact_store'
end

local function recv_or_fail(ch)
	local v, err = fibers.perform(ch:get_op())
	assert(v, tostring(err))
	return v
end

local function mk_tmpdir(tag)
	local path = ('/tmp/dc-lua-%s-%d-%06d'):format(tag, os.time(), math.random(0, 999999))
	local ok = os.execute(('mkdir -p %q'):format(path))
	assert(ok == true or ok == 0, 'failed to create temp dir: ' .. path)
	return path
end

local function rm_rf(path)
	os.execute(('rm -rf %q'):format(path))
end

function T.apply_config_fails_when_not_started()
	local M = fresh_manager()

	runfibers.run(function()
		local ok, err = fibers.perform(M.apply_config_op({
			stores = {
				{ id = 'main', transient_root = '/tmp/a', durable_root = '/tmp/b', durable_enabled = false },
			},
		}))
		assert(ok == false)
		assert(tostring(err):match('not started'))
	end)
end

function T.start_apply_config_and_stop_round_trip()
	local M = fresh_manager()
	local base = mk_tmpdir('as-manager-start')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local ok_cfg, err_cfg = fibers.perform(M.apply_config_op({
			stores = {
				{
					id = 'main',
					transient_root = transient_root,
					durable_root = durable_root,
					durable_enabled = false,
				},
			},
		}))
		assert(ok_cfg == true, tostring(err_cfg))

		local ev = recv_or_fail(dev_ev_ch)
		assert(ev.event_type == 'added')
		assert(ev.class == 'artifact_store')
		assert(ev.id == 'main')
		assert(#ev.capabilities == 1)
		assert(ev.capabilities[1].class == 'artifact_store')
		assert(ev.capabilities[1].offerings.create_sink == true)

		local e1 = recv_or_fail(cap_emit_ch)
		local e2 = recv_or_fail(cap_emit_ch)

		local by_mode = {
			[e1.mode] = e1,
			[e2.mode] = e2,
		}

		assert(by_mode.meta ~= nil)
		assert(by_mode.state ~= nil)
		assert(by_mode.meta.class == 'artifact_store')
		assert(by_mode.meta.id == 'main')
		assert(by_mode.meta.data.transient_root == transient_root)
		assert(by_mode.meta.data.durable_root == durable_root)
		assert(by_mode.state.data.state == 'available')

		local ok_stop, err_stop = fibers.perform(M.stop_op())
		assert(ok_stop == true, tostring(err_stop))
	end)

	rm_rf(base)
end

function T.reapply_same_config_is_idempotent()
	local M = fresh_manager()
	local base = mk_tmpdir('as-manager-same')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local cfg = {
			stores = {
				{
					id = 'main',
					transient_root = transient_root,
					durable_root = durable_root,
					durable_enabled = false,
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

	rm_rf(base)
end

function T.config_change_removes_then_adds_provider()
	local M = fresh_manager()
	local base = mk_tmpdir('as-manager-change')
	local transient_root_a = base .. '/transient-a'
	local transient_root_b = base .. '/transient-b'
	local durable_root = base .. '/durable'

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local ok1, err1 = fibers.perform(M.apply_config_op({
			stores = {
				{
					id = 'main',
					transient_root = transient_root_a,
					durable_root = durable_root,
					durable_enabled = false,
				},
			},
		}))
		assert(ok1 == true, tostring(err1))
		local first = recv_or_fail(dev_ev_ch)
		assert(first.event_type == 'added')

		local ok2, err2 = fibers.perform(M.apply_config_op({
			stores = {
				{
					id = 'main',
					transient_root = transient_root_b,
					durable_root = durable_root,
					durable_enabled = false,
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

	rm_rf(base)
end

function T.invalid_config_is_rejected()
	local M = fresh_manager()

	runfibers.run(function()
		local dev_ev_ch = channel.new(8)
		local cap_emit_ch = channel.new(8)

		local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
		assert(ok_start == true, tostring(err_start))

		local ok_cfg, err_cfg = fibers.perform(M.apply_config_op({
			stores = 'nope',
		}))
		assert(ok_cfg == false)
		assert(tostring(err_cfg):match('stores must be a table'))

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
