local fibers     = require 'fibers'
local channel    = require 'fibers.channel'
local runfibers  = require 'tests.support.run_fibers'

local T = {}

local function mk_tmpdir(tag)
  local path = ('/tmp/dc-lua-%s-%d-%06d'):format(tag, os.time(), math.random(0, 999999))
  local ok = os.execute(('mkdir -p %q'):format(path))
  assert(ok == true or ok == 0, 'failed to create temp dir: ' .. path)
  return path
end

local function rm_rf(path)
  os.execute(('rm -rf %q'):format(path))
end

local function fresh_manager()
  package.loaded['services.hal.managers.control_store'] = nil
  package.loaded['services.hal.drivers.control_store'] = nil
  package.loaded['services.hal.drivers.control_store_provider'] = nil
  return require('services.hal.managers.control_store')
end

local function recv_or_fail(ch)
  local v, err = fibers.perform(ch:get_op())
  assert(v ~= nil, tostring(err))
  return v
end

function T.start_apply_config_and_stop_round_trip()
  local root = mk_tmpdir('csm-roundtrip')
  local M = fresh_manager()

  runfibers.run(function(scope)
    local dev_ev_ch = channel.new(8)
    local cap_emit_ch = channel.new(8)

    local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
    assert(ok_start == true, tostring(err_start))

    local ok_cfg, err_cfg = fibers.perform(M.apply_config_op({
      { name = 'main', root = root },
    }))
    assert(ok_cfg == true, tostring(err_cfg))

    local ev = recv_or_fail(dev_ev_ch)
    assert(ev.event_type == 'added')
    assert(ev.class == 'control-store')
    assert(ev.id == 'main')
    assert(type(ev.capabilities) == 'table' and #ev.capabilities == 1)

    local ok_stop, err_stop = fibers.perform(M.shutdown_op())
    assert(ok_stop == true, tostring(err_stop))
  end)

  rm_rf(root)
end

function T.apply_config_creates_missing_control_store_root()
  local base = mk_tmpdir('csm-create-root')
  local root = base .. '/nested/control-store'
  local M = fresh_manager()

  runfibers.run(function()
    local dev_ev_ch = channel.new(8)
    local cap_emit_ch = channel.new(8)

    local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
    assert(ok_start == true, tostring(err_start))

    local ok_cfg, err_cfg = fibers.perform(M.apply_config_op({
      { name = 'main', root = root },
    }))
    assert(ok_cfg == true, tostring(err_cfg))

    local ev = recv_or_fail(dev_ev_ch)
    assert(ev.event_type == 'added')
    assert(ev.class == 'control-store')
    assert(ev.id == 'main')

    local probe, perr = io.open(root .. '/.probe', 'wb')
    assert(probe ~= nil, tostring(perr))
    probe:write('ok')
    probe:close()

    local ok_stop, err_stop = fibers.perform(M.shutdown_op())
    assert(ok_stop == true, tostring(err_stop))
  end)

  rm_rf(base)
end

function T.apply_config_fails_when_not_started()
  local root = mk_tmpdir('csm-not-started')
  local M = fresh_manager()

  runfibers.run(function()
    local ok, err = fibers.perform(M.apply_config_op({
      { name = 'main', root = root },
    }))
    assert(ok == false)
    assert(tostring(err):match('not started'))
  end)

  rm_rf(root)
end

function T.cap_emit_channel_receives_initial_meta_and_state()
  local root = mk_tmpdir('csm-emit')
  local M = fresh_manager()

  runfibers.run(function()
    local dev_ev_ch = channel.new(8)
    local cap_emit_ch = channel.new(8)

    local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
    assert(ok_start == true, tostring(err_start))

    local ok_cfg, err_cfg = fibers.perform(M.apply_config_op({
      { name = 'main', root = root },
    }))
    assert(ok_cfg == true, tostring(err_cfg))

    local e1 = recv_or_fail(cap_emit_ch)
    local e2 = recv_or_fail(cap_emit_ch)

    local by_mode = {
      [e1.mode] = e1,
      [e2.mode] = e2,
    }

    assert(by_mode.meta ~= nil)
    assert(by_mode.state ~= nil)
    assert(by_mode.meta.class == 'control-store')
    assert(by_mode.meta.id == 'main')
    assert(by_mode.meta.key == 'details')
    assert(by_mode.meta.data.root == root)
    assert(by_mode.state.key == 'status')
    assert(by_mode.state.data.state == 'available')

    local ok_stop, err_stop = fibers.perform(M.shutdown_op())
    assert(ok_stop == true, tostring(err_stop))
  end)

  rm_rf(root)
end

function T.reapply_same_config_is_idempotent()
  local root = mk_tmpdir('csm-idempotent')
  local M = fresh_manager()

  runfibers.run(function()
    local dev_ev_ch = channel.new(8)
    local cap_emit_ch = channel.new(8)

    local ok_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
    assert(ok_start == true)

    local ok1, err1 = fibers.perform(M.apply_config_op({ { name = 'main', root = root } }))
    assert(ok1 == true, tostring(err1))
    local added = recv_or_fail(dev_ev_ch)
    assert(added.event_type == 'added')

    local ok2, err2 = fibers.perform(M.apply_config_op({ { name = 'main', root = root } }))
    assert(ok2 == true, tostring(err2))

    local which = fibers.perform(require('fibers').named_choice{
      msg = dev_ev_ch:get_op():wrap(function(v) return 'msg', v end),
      timeout = require('fibers.sleep').sleep_op(0.05):wrap(function() return 'timeout' end),
    })
    assert(which == 'timeout', 'reapplying same config should not emit new device events')

    local ok_stop, err_stop = fibers.perform(M.shutdown_op())
    assert(ok_stop == true, tostring(err_stop))
  end)

  rm_rf(root)
end

function T.reconcile_root_change_emits_removed_then_added()
  local root1 = mk_tmpdir('csm-root1')
  local root2 = mk_tmpdir('csm-root2')
  local M = fresh_manager()

  runfibers.run(function()
    local dev_ev_ch = channel.new(8)
    local cap_emit_ch = channel.new(8)

    local ok_start, err_start = fibers.perform(M.start_op(nil, dev_ev_ch, cap_emit_ch))
    assert(ok_start == true, tostring(err_start))

    local ok1, err1 = fibers.perform(M.apply_config_op({ { name = 'main', root = root1 } }))
    assert(ok1 == true, tostring(err1))
    local first = recv_or_fail(dev_ev_ch)
    assert(first.event_type == 'added')

    local ok2, err2 = fibers.perform(M.apply_config_op({ { name = 'main', root = root2 } }))
    assert(ok2 == true, tostring(err2))

    local ev_a = recv_or_fail(dev_ev_ch)
    local ev_b = recv_or_fail(dev_ev_ch)
    assert(ev_a.event_type == 'removed')
    assert(ev_b.event_type == 'added')
    assert(ev_b.id == 'main')

    local ok_stop, err_stop = fibers.perform(M.shutdown_op())
    assert(ok_stop == true, tostring(err_stop))
  end)

  rm_rf(root1)
  rm_rf(root2)
end

function T.shutdown_op_before_start_is_ok_and_fault_op_is_inert()
  local M = fresh_manager()

  runfibers.run(function()
    local ok_stop, err_stop = fibers.perform(M.shutdown_op())
    assert(ok_stop == true, tostring(err_stop))

    local which = fibers.perform(fibers.named_choice{
      fault = M.fault_op():wrap(function(...) return 'fault', ... end),
      timeout = require('fibers.sleep').sleep_op(0.05):wrap(function() return 'timeout' end),
    })
    assert(which == 'timeout')
  end)
end

return T
