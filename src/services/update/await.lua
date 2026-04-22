local fibers = require 'fibers'
local scope = require 'fibers.scope'
local sleep = require 'fibers.sleep'

local M = {}

local function until_changed_or_timeout_blocking(opts)
    assert(type(opts) == 'table', 'await.until_changed_or_timeout: opts must be a table')
    assert(type(opts.version) == 'function', 'await.until_changed_or_timeout: version() required')
    assert(type(opts.changed_op) == 'function', 'await.until_changed_or_timeout: changed_op() required')
    assert(type(opts.evaluate) == 'function', 'await.until_changed_or_timeout: evaluate() required')

    local timeout_s = assert(tonumber(opts.timeout_s), 'await.until_changed_or_timeout: timeout_s required')
    local deadline = fibers.now() + timeout_s

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

        local remaining = deadline - fibers.now()
        if remaining <= 0 then
            return 'timeout', nil
        end

        local which = fibers.perform(fibers.named_choice({
            changed = opts.changed_op(seen),
            timeout = sleep.sleep_op(remaining):wrap(function() return true end),
        }))

        if which == 'timeout' then
            return 'timeout', nil
        end
    end
end

function M.until_changed_or_timeout_op(opts)
    return fibers.run_scope_op(function()
        return until_changed_or_timeout_blocking(opts)
    end):wrap(function(st, _rep, outcome, result)
        if st == 'ok' then
            return outcome, result
        elseif st == 'cancelled' then
            return 'cancelled', outcome
        else
            return 'error', outcome
        end
    end)
end

function M.until_changed_or_timeout(opts)
    local outcome, result = fibers.perform(M.until_changed_or_timeout_op(opts))
    if outcome == 'cancelled' then
        error(scope.cancelled(result), 0)
    elseif outcome == 'error' then
        error(result or 'await_failed', 0)
    end
    return outcome, result
end

return M
