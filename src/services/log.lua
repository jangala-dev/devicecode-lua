-- services/log.lua
--
-- Log service (new fibers):
--  - singleton logger: log.trace/debug/info/warn/error/fatal callable from any service
--  - when conn is set (after start), publishes log entries to {'logs', <level>}
--  - publishes service lifecycle status to {'svc', <name>, 'status'}

local rxilog  = require 'rxilog'
local runtime = require 'fibers.runtime'
local fibers  = require 'fibers'
local sleep   = require 'fibers.sleep'
local perform = require 'fibers.performer'.perform

local log_service = {}

local function t(...)
    return { ... }
end

local function now()
    return runtime.now()
end

local function publish_status(conn, name, state, extra)
    local payload = { state = state, ts = now() }
    if type(extra) == 'table' then
        for k, v in pairs(extra) do payload[k] = v end
    end
    conn:retain(t('svc', name, 'status'), payload)
end

-- Level methods: always log to console; publish to bus when a connection is set.
for _, mode in ipairs(rxilog.modes) do
    local level = mode.name
    log_service[level] = function(...)
        local msg = rxilog.tostring(...)
        rxilog[level](msg)

        if log_service._conn then
            local info     = debug.getinfo(2, "Sl")
            local lineinfo = info.short_src .. ":" .. info.currentline
            local time_utils = require 'fibers.utils.time'
            log_service._conn:publish(t('logs', level), {
                message   = rxilog.format_log_message(level:upper(), lineinfo, msg),
                timestamp = time_utils.realtime(),
            })
        end
    end
end

function log_service.start(conn, opts)
    opts = opts or {}
    local name = opts.name or 'log'

    publish_status(conn, name, 'starting')

    fibers.current_scope():finally(function()
        log_service._conn = nil
        publish_status(conn, name, 'stopped')
        rxilog.trace("Log: stopped")
    end)

    log_service._conn  = conn
    log_service._name  = name

    publish_status(conn, name, 'running')
    log_service.trace("Log service started")

    -- Block until scope is cancelled or fails (sleep_op is interrupted by cancellation).
    while true do
        perform(sleep.sleep_op(math.huge))
    end
end

-- Make singleton
package.loaded["services.log"] = log_service
return log_service
