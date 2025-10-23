local log = require 'services.log'
local service = require 'service'
local cjson = require 'cjson.safe'
local new_msg = require 'bus'.new_msg

local mcu_bridge = {
    name = 'mcu_bridge'
}
mcu_bridge.__index = mcu_bridge

local function read_uart_data(ctx)
    local uart_cap_sub = mcu_bridge.conn:subscribe({ 'hal', 'capability', 'uart', 'uart0' })
    uart_cap_sub:next_msg_with_context(ctx)
    log.trace(string.format(
        "%s - %s: Dectected UART capability",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
    uart_cap_sub:unsubscribe()
    local req = mcu_bridge.conn:request(new_msg(
        { 'hal', 'capability', 'uart', 'uart0', 'control', 'open' },
        { { baudrate = 115200, read = true, write = true } }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    if ctx_err or resp.payload.err then
        log.error(string.format(
            "%s - %s: Failed to open UART port: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            ctx_err or resp.payload.err
        ))
        return
    else
        log.info(string.format(
            "%s - %s: UART port opened successfully",
            ctx:value("service_name"),
            ctx:value("fiber_name")
        ))
    end
    req:unsubscribe()

    local uart_data_sub = mcu_bridge.conn:subscribe({ 'hal', 'capability', 'uart', 'uart0', 'info', 'out' })
    while not ctx:err() do
        local msg, sub_err = uart_data_sub:next_msg_with_context(ctx)
        if sub_err then
            log.error(string.format(
                "%s - %s: Error receiving UART data: %s",
                ctx:value("service_name"),
                ctx:value("fiber_name"),
                sub_err
            ))
            break
        end
        if msg and msg.payload then
            local decoded, decode_err = cjson.decode(msg.payload)
            if decode_err then
                log.error(string.format(
                    "%s - %s: Error decoding UART JSON data: %s \"%s\"",
                    ctx:value("service_name"),
                    ctx:value("fiber_name"),
                    decode_err,
                    msg.payload
                ))
            else
                for k, v in pairs(decoded) do
                    local key_table = { 'mcu'}
                    for segment in string.gmatch(k, "[^/]+") do
                        table.insert(key_table, segment)
                    end
                    mcu_bridge.conn:publish(new_msg(
                        key_table,
                        v
                    ))
                end
            end
        end
    end
    uart_data_sub:unsubscribe()
end

function mcu_bridge:start(ctx, conn)
    self.ctx = ctx
    self.conn = conn
    -- Placeholder for future implementation

    service.spawn_fiber('UART Reader', conn, ctx, read_uart_data)
end

return mcu_bridge
