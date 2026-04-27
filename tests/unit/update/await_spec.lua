local fibers = require 'fibers'
local runfibers = require 'tests.support.run_fibers'
local pulse = require 'fibers.pulse'
local sleep = require 'fibers.sleep'
local await_mod = require 'services.update.await'

local T = {}

function T.await_returns_success_after_change()
  runfibers.run(function(scope)
    local p = pulse.scoped({ close_reason = 'done' })
    local done = false
    local progress = 0
    local ok, err = scope:spawn(function()
      sleep.sleep(0.01)
      progress = 1
      p:signal()
      sleep.sleep(0.01)
      done = true
      p:signal()
    end)
    assert(ok, tostring(err))

    local outcome, result = await_mod.until_changed_or_timeout({
      timeout_s = 0.25,
      version = function() return p:version() end,
      changed_op = function(seen) return p:changed_op(seen) end,
      evaluate = function()
        if done then return { done = true, success = true, value = 'ok' } end
        if progress > 0 then return { done = false, progress = progress } end
        return nil
      end,
    })

    assert(outcome == 'success')
    assert(type(result) == 'table' and result.value == 'ok')
  end, { timeout = 1.0 })
end

function T.await_accepts_absolute_deadline()
  runfibers.run(function()
    local p = pulse.scoped({ close_reason = 'done' })
    local deadline = fibers.now() + 0.02
    local outcome = await_mod.until_changed_or_timeout({
      deadline = deadline,
      version = function() return p:version() end,
      changed_op = function(seen) return p:changed_op(seen) end,
      evaluate = function() return nil end,
    })
    assert(outcome == 'timeout')
  end, { timeout = 1.0 })
end

function T.await_times_out_when_no_change_occurs()
  runfibers.run(function()
    local p = pulse.scoped({ close_reason = 'done' })
    local outcome = await_mod.until_changed_or_timeout({
      timeout_s = 0.02,
      version = function() return p:version() end,
      changed_op = function(seen) return p:changed_op(seen) end,
      evaluate = function() return nil end,
    })
    assert(outcome == 'timeout')
  end, { timeout = 1.0 })
end

return T
