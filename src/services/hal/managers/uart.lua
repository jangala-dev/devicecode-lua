local context = require "fibers.context"
local queue = require "fibers.queue"
local op = require "fibers.op"
local log = require "services.log"
local service = require "service"
local uart_driver = require "services.hal.drivers.uart"

local UARTManagement = {}
UARTManagement.__index = UARTManagement

function UARTManagement:apply_config(config)
    self._config_apply_q:put(config)
end

function UARTManagement:_apply_config(ctx, conn, device_event_q, capability_info_q, config)
    log.trace(string.format(
        "%s - %s: Applying configuration",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    if not config.serial_ports or type(config.serial_ports) ~= "table" then
        log.error(string.format(
            "%s - %s: No serial ports configured",
            ctx:value("service_name"),
            ctx:value("fiber_name")
        ))
        return
    end

    for name, driver in pairs(self._uart_drivers) do
        if not config.serial_ports[name] then
            driver.ctx:cancel()
            self._uart_drivers[name] = nil
            device_event_q:put({
                connected = false,
                type = "uart",
                id_field = "name",
                data = {
                    name = name
                }
            })
        end
    end

    for _, port_cfg in ipairs(config.serial_ports) do
        local driver = self._uart_drivers[port_cfg.name]
        if driver and driver:get_port() ~= port_cfg.path then
            driver.ctx:cancel()
            self._uart_drivers[port_cfg.name] = nil
            device_event_q:put({
                connected = false,
                type = "uart",
                id_field = "name",
                data = {
                    name = port_cfg.name
                }
            })
            driver = nil
        end

        if not driver then
            local driver_ctx = context.with_cancel(ctx)
            driver = uart_driver.new(driver_ctx, port_cfg.name, port_cfg.path)
            self._uart_drivers[port_cfg.name] = driver
            driver:spawn(conn)
            local capabilities = driver:apply_capabilities(capability_info_q)
            device_event_q:put({
                connected = true,
                type = "uart",
                id_field = "name",
                capabilities = capabilities,
                data = {
                    name = port_cfg.name
                }
            })
        end
    end
end

function UARTManagement:_manager(ctx, conn, device_event_q, capability_info_q)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    while not ctx:err() do
        op.choice(
            self._config_apply_q:get_op():wrap(function(config)
                self:_apply_config(ctx, conn, device_event_q, capability_info_q, config)
            end),
            ctx:done_op()
        ):perform()
    end

    log.trace(string.format(
        "%s - %s: Stopping",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

function UARTManagement:spawn(ctx, conn, device_event_q, capability_info_q)
    service.spawn_fiber("UART Manager", conn, ctx, function(fctx)
        self:_manager(fctx, conn, device_event_q, capability_info_q)
    end)
end

local function new()
    local uart_management = {
        _config_apply_q = queue.new(10),
        _uart_drivers = {}
    }
    return setmetatable(uart_management, UARTManagement)
end

return { new = new }
