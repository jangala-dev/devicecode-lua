-- services/update/await.lua
--
-- Small reconcile waiting helper.

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'

local perform = fibers.perform
local named_choice = fibers.named_choice
local now = fibers.now

local M = {}

function M.until_changed_or_timeout(opts)
  assert(type(opts) == 'table', 'await.until_changed_or_timeout: opts must be a table')
  assert(type(opts.version) == 'function', 'await.until_changed_or_timeout: version() required')
  assert(type(opts.changed_op) == 'function', 'await.until_changed_or_timeout: changed_op() required')
  assert(type(opts.evaluate) == 'function', 'await.until_changed_or_timeout: evaluate() required')

  local timeout_s = assert(tonumber(opts.timeout_s), 'await.until_changed_or_timeout: timeout_s required')
  local deadline = now() + timeout_s

  while true do
    local seen = opts.version()
    local result = opts.evaluate()

    if result ~= nil then
      if result.done then
        if result.success then
          return 'success', result
        end
        return 'failure', result
      end
      if opts.on_progress then
        opts.on_progress(result)
      end
    end

    local remaining = deadline - now()
    if remaining <= 0 then
      return 'timeout', nil
    end

    local which = perform(named_choice({
      changed = opts.changed_op(seen),
      timeout = sleep.sleep_op(remaining):wrap(function()
        return true
      end),
    }))

    if which == 'timeout' then
      return 'timeout', nil
    end
  end
end

return M
