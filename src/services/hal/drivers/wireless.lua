local fiber = require "fibers.fiber"
local op = require "fibers.op"
local queue = require "fibers.queue"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local service = require "service"
local log = require "services.log"
local hal_capabilities = require "services.hal.hal_capabilities"
local iw = require "services.hal.drivers.wireless.iw"
local utils = require "services.hal.drivers.wireless.utils"
local sc = require "fibers.utils.syscall"

local unpack = table.unpack or unpack

local DEFAULT_REPORT_PERIOD = 3600

---@class WirelessDriver
---@field ctx Context The driver's context
---@field interface string
---@field report_period_ch Channel Channel for setting the report period of metrics
---@field client_event_ch Channel Channel for receiving client events
---@field command_q Queue Queue for receiving commands
---@field info_q Queue Queue for sending information updates
local WirelessDriver = {}
WirelessDriver.__index = WirelessDriver

-------------------------------------------------------------------------
--- WirelessDriverCapabilities -------------------------------------------

function WirelessDriver:set_report_period(ctx, period)
    op.choice(
        self.report_period_ch:put_op(period),
        ctx:done_op()
    ):perform()
    return ctx:err() == nil, ctx:err()
end

-------------------------------------------------------------------------
-------------------------------------------------------------------------

--- Register and apply driver capabilities
--- @param capability_info_q Queue Queue for sending capability information updates
--- @return table capabilities The capabilities exposed by this driver
--- @return string? error Error message if capabilities couldn't be applied
function WirelessDriver:apply_capabilities(capability_info_q)
    self.info_q = capability_info_q

    -- Example of registering capabilities - customize based on driver needs
    local capabilities = {
        example = {
            control = hal_capabilities.new_wireless_capability(self.command_q),
            id = "1" -- unique identifier for this capability instance
        }
    }

    return capabilities, nil
end

--- Handle a capability request
--- @param ctx Context
--- @param request table The capability request to handle
function WirelessDriver:handle_capability(ctx, request)
    local command = request.command
    local args = request.args or {}
    local ret_ch = request.return_channel

    if type(ret_ch) == 'nil' then return end

    if type(command) == "nil" then
        ret_ch:put({
            result = nil,
            err = 'No command was provided'
        })
        return
    end

    local func = self[command]
    if type(func) ~= "function" then
        ret_ch:put({
            result = nil,
            err = "Command does not exist"
        })
        return
    end

    fiber.spawn(function()
        local result, err = func(self, ctx, unpack(args))

        ret_ch:put({
            result = result,
            err = err
        })
    end)
end

--- Main driver loop
--- @param ctx Context The driver's context
function WirelessDriver:_main(ctx)
    log.info(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    -- Main event loop
    while not ctx:err() do
        op.choice(
            self.command_q:get_op():wrap(function(req)
                self:handle_capability(ctx, req)
            end),
            self.ctx:done_op()
        ):perform()
    end

    log.info(string.format(
        "%s - %s: Exiting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

function WirelessDriver:_monitor_clients(ctx)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    local cmd = iw.get_iw_event_stream(ctx)
    local stdout = cmd:stdout_pipe()
    if not stdout then
        log.error(string.format(
            "%s - %s: Failed to get stdout pipe for iw event stream",
            ctx:value("service_name"),
            ctx:value("fiber_name")
        ))
        cmd:kill()
        cmd:wait()
        return
    end

    local err = cmd:start()
    if err then
        log.error(string.format(
            "%s - %s: Failed to start iw event stream, reason: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            err
        ))
        stdout:close()
        return
    end

    local done = false
    while not ctx:err() and not done do
        op.choice(
            stdout:read_line_op():wrap(function(line)
                if not line then
                    ctx:cancel("command closed")
                    return
                end
                -- Pattern: interface: (new|del) station <mac>
                local iface, event, mac = string.match(line, "^([%w%-]+):%s*(new)%s+station%s+([%x:]+)")
                if not iface then
                    iface, event, mac = string.match(line, "^([%w%-]+):%s*(del)%s+station%s+([%x:]+)")
                end
                if iface and event and mac then
                    if iface == self.interface then
                        op.choice(
                            self.client_event_ch:put_op({
                                connected = event == "new" and true or false,
                                mac = mac
                            }),
                            ctx:done_op()
                        ):perform()
                    end
                end
            end),
            ctx:done_op():wrap(function()
                cmd:kill()
                done = true
            end)
        ):perform()
    end
    cmd:wait()
    stdout:close()

    log.trace(string.format(
        "%s - %s: Exiting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

local function get_iface_stats(ctx, interface)
    local net_statistics = {
        "rx_bytes",
        "tx_bytes",
        "rx_packets",
        "tx_packets",
        "rx_dropped",
        "tx_dropped",
        "rx_errors",
        "tx_errors",
    }
    local stats = {}

    local info, info_err = iw.get_iw_dev_info(ctx, interface)
    if not info_err then
        for k, v in pairs(info) do
            stats[k] = v
        end
    end

    for _, stat in ipairs(net_statistics) do
        local value, value_err = utils.get_net_statistic(interface, stat)
        if not value_err then
            stats[stat] = value
        end
    end

    return stats
end

function WirelessDriver:_report_metrics(ctx)
    local report_period = DEFAULT_REPORT_PERIOD
    local next_report = sc.monotime() + report_period
    local clients = {}

    while not ctx:err() do
        op.choice(
            self.report_period_ch:get_op():wrap(function(period)
                next_report = next_report - report_period + period -- Adjust next_report for new period
                report_period = period
            end),
            self.client_event_ch:get_op():wrap(function(event)
                if not event then return end
                if type(event.connected) ~= "nil" then
                    self.info_q:put({
                        type = "wireless",
                        id = self.interface,
                        sub_topic = { "clients", event.mac },
                        endpoints = "single",
                        info = {
                            connected = event.connected,
                            timestamp = sc.monotime()
                        }
                    })
                end
                if event.connected then
                    clients[event.mac] = true
                    local client_info, client_err = iw.get_client_info(ctx, self.interface, event.mac)
                    if not client_err then
                        self.info_q:put({
                            type = "wireless",
                            id = self.interface,
                            sub_topic = { "clients" },
                            endpoints = "multiple",
                            info = { [event.mac] = client_info }
                        })
                    end
                else
                    clients[event.mac] = nil
                end
            end),
            sleep.sleep_until_op(next_report):wrap(function()
                local stats = get_iface_stats(ctx, self.interface)
                if next(stats) then
                    self.info_q:put({
                        type = "wireless",
                        id = self.interface,
                        sub_topic = {},
                        endpoints = "multiple",
                        info = stats
                    })
                end

                local client_stats = {}
                for mac, _ in pairs(clients) do
                    local client_info, client_err = iw.get_client_info(ctx, self.interface, mac)
                    if not client_err then
                        client_stats[mac] = client_info
                    end
                end
                if next(client_stats) then
                    self.info_q:put({
                        type = "wireless",
                        id = self.interface,
                        sub_topic = { "clients" },
                        endpoints = "multiple",
                        info = client_stats
                    })
                end
                next_report = sc.monotime() + report_period
            end),
            ctx:done_op()
        ):perform()
    end
end

--- Spawn driver fiber
--- @param conn Connection The bus connection
function WirelessDriver:spawn(conn)
    service.spawn_fiber("Wireless Main", conn, self.ctx, function(fctx)
        self:_main(fctx)
    end)
    service:spawn_fiber("Wireless Client Monitor", conn, self.ctx, function(fctx)
        self:_monitor_clients(fctx)
    end)
    service:spawn_fiber("Wireless Metrics Reporter", conn, self.ctx, function(fctx)
        self:_report_metrics(fctx)
    end)
end

--- Create a new driver instance
--- @param ctx Context The context for this driver
--- @return WirelessDriver The new driver instance
local function new(ctx, interface)
    local self = setmetatable({}, WirelessDriver)
    self.ctx = ctx
    self.command_q = queue.new(10)
    self.interface = interface
    self.report_period_ch = channel.new()
    self.client_event_ch = channel.new()

    return self
end

return {
    new = new
}
