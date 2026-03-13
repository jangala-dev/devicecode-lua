-- services/mcu_bridge.lua
--
-- MCU Bridge service (new fibers):
--  - waits for the uart0 capability from HAL
--  - opens the UART port read-only
--  - reads JSON lines, decodes them, caches values, and publishes only
--    changed values onto the bus under the 'mcu' topic prefix

local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'

local perform = fibers.perform

local log            = require 'services.log'
local external_types = require 'services.hal.types.external'
local cache          = require 'shared.cache'
local cjson          = require 'cjson.safe'

---- Constants ----

local DEFAULT_UART_ID         = 'uart0'
local CAP_WAIT_TIMEOUT        = 10   -- seconds between "still waiting" warnings
local RPC_TIMEOUT             = 10   -- seconds for UART open/close RPC calls
local UNDERFLOW_THRESHOLD     = 1000000
local ERR_LOG_COOLDOWN_MIN    = 1    -- seconds (doubles on each failure, capped below)
local ERR_LOG_COOLDOWN_MAX    = 60   -- seconds

---- Service Helpers ----

---@param conn Connection
---@param name string
---@param state string
---@param extra table?
local function publish_status(conn, name, state, extra)
    local payload = { state = state, ts = fibers.now() }
    if type(extra) == 'table' then
        for k, v in pairs(extra) do payload[k] = v end
    end
    conn:retain({ 'svc', name, 'status' }, payload)
end

---- Topic Builders ----
-- All bus topics are built here. Any topic or HAL API changes only
-- require edits in this section.

--- Convert a slash-delimited MCU key into a bus topic with 'mcu' prepended.
--- e.g. "power/temperature/internal" → {'mcu', 'power', 'temperature', 'internal'}
---@param key string
---@return string[]
local function t_mcu(key)
    local topic = { 'mcu' }
    for segment in string.gmatch(key, "[^/]+") do
        table.insert(topic, segment)
    end
    return topic
end

---@param id string
---@return string[]
local function t_uart_state(id)
    return { 'cap', 'uart', id, 'state' }
end

---@param id string
---@param method string
---@return string[]
local function t_uart_rpc(id, method)
    return { 'cap', 'uart', id, 'rpc', method }
end

---@param id string
---@param name string
---@return string[]
local function t_uart_event(id, name)
    return { 'cap', 'uart', id, 'event', name }
end

---- UART Endpoint Wrappers ----
-- Each wrapper isolates one HAL interaction behind a stable local interface.

--- Send the 'open' RPC to the UART driver and wait for a reply.
---@param conn Connection
---@param id string
---@return boolean ok
---@return string error
local function open_uart(conn, id)
    local opts, opts_err = external_types.new.UARTOpenOpts(true, false)
    if not opts then
        return false, opts_err or "failed to create UARTOpenOpts"
    end
    local reply, err = conn:call(t_uart_rpc(id, 'open'), opts, { timeout = RPC_TIMEOUT })
    if not reply then
        return false, err or "open rpc failed"
    end
    if not reply.ok then
        return false, reply.reason or "open rpc returned not ok"
    end
    return true, ""
end

--- Send the 'close' RPC to the UART driver and wait for a reply.
---@param conn Connection
---@param id string
---@return boolean ok
---@return string error
local function close_uart(conn, id)
    local reply, err = conn:call(t_uart_rpc(id, 'close'), {}, { timeout = RPC_TIMEOUT })
    if not reply then
        return false, err or "close rpc failed"
    end
    if not reply.ok then
        return false, reply.reason or "close rpc returned not ok"
    end
    return true, ""
end

---- Utility Functions ----

---@param s string
---@return string
local function trim(s)
    local result = s:gsub("^%s*(.-)%s*$", "%1")
    return result
end

--- Fix integer underflow: cjson represents some negative numbers as large
--- positive numbers when the 32-bit signed value wraps. Values above
--- UNDERFLOW_THRESHOLD are assumed to have wrapped and are corrected.
---@param tbl table
---@return table
local function fix_underflows(tbl)
    for k, v in pairs(tbl) do
        if type(v) == 'number' and v > UNDERFLOW_THRESHOLD then
            tbl[k] = v - 2 ^ 32
        end
    end
    return tbl
end

---- Service ----

---@class McuBridgeService
local McuBridgeService = {}

---@param conn Connection
---@param opts table?
---@return nil
function McuBridgeService.start(conn, opts)
    opts = opts or {}
    local name    = opts.name    or 'mcu_bridge'
    local uart_id = opts.uart_id or DEFAULT_UART_ID

    publish_status(conn, name, 'starting')

    local uart_opened = false
    local scope = fibers.current_scope()

    scope:finally(function(_, st, primary)
        if uart_opened then
            local ok, err = close_uart(conn, uart_id)
            if not ok then
                log.warn("MCU Bridge", "- failed to close UART on shutdown:", err)
            end
        end
        log.trace("MCU Bridge", "- stopped:", primary or st)
        publish_status(conn, name, 'stopped', { reason = primary or st })
    end)

    -- Phase 1: wait for the UART capability to appear.
    -- The HAL retains {'cap', 'uart', id, 'state'} so we will receive the
    -- current state immediately if the capability already exists.
    local cap_state_sub = conn:subscribe(t_uart_state(uart_id))
    log.trace("MCU Bridge", "- waiting for UART capability", uart_id)

    while true do
        local which, msg = perform(op.named_choice({
            cap     = cap_state_sub:recv_op(),
            timeout = sleep.sleep_op(CAP_WAIT_TIMEOUT),
        }))

        if which == 'timeout' then
            log.warn("MCU Bridge", "- still waiting for UART capability", uart_id)
        else
            if not msg then
                log.warn("MCU Bridge", "- UART capability subscription closed unexpectedly")
                return
            end
            if msg.payload == 'added' then
                break
            end
            -- payload 'removed' or unknown: capability not yet ready, keep waiting
        end
    end
    cap_state_sub:unsubscribe()

    -- Phase 2: open the UART port for reading.
    local ok, open_err = open_uart(conn, uart_id)
    if not ok then
        log.error("MCU Bridge", "- failed to open UART", uart_id, ":", open_err)
        return
    end
    uart_opened = true

    -- Phase 3: subscribe to output lines and process them.
    local out_sub    = conn:subscribe(t_uart_event(uart_id, 'out'))
    local val_cache  = cache.new(math.huge)

    -- Error-log cooldown state: avoids log spam when the MCU sends bad JSON.
    local time_to_next_err_log = 0
    local err_log_cooldown     = ERR_LOG_COOLDOWN_MIN

    publish_status(conn, name, 'running')
    log.trace("MCU Bridge", "- running, reading from UART", uart_id)

    while true do
        local which, msg, sub_err = perform(op.named_choice({
            out   = out_sub:recv_op(),
            fault = scope:not_ok_op(),
        }))

        if which == 'fault' then
            break
        end

        -- which == 'out'
        if not msg then
            log.debug("MCU Bridge", "- UART output subscription closed:", sub_err)
            break
        end

        local line = trim(tostring(msg.payload))
        if line ~= '' then
            local decoded, decode_err = cjson.decode(line)
            if decode_err then
                local now_t = os.time()
                if now_t >= time_to_next_err_log then
                    log.error("MCU Bridge", "- JSON decode error:", decode_err, "| raw:", line)
                    err_log_cooldown     = math.min(err_log_cooldown * 2, ERR_LOG_COOLDOWN_MAX)
                    time_to_next_err_log = now_t + err_log_cooldown
                end
            else
                local fixed = fix_underflows(decoded)
                for k, v in pairs(fixed) do
                    local cached = val_cache:get(k)
                    if cached ~= v then
                        val_cache:set(k, v)
                        conn:publish(t_mcu(k), v)
                    end
                end
            end
        end
    end

    out_sub:unsubscribe()
end

return McuBridgeService
