local fiber = require "fibers.fiber"
local op = require "fibers.op"
local queue = require "fibers.queue"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local service = require "service"
local log = require "services.log"
local hal_capabilities = require "services.hal.hal_capabilities"
local iw = require "services.hal.drivers.wireless.iw"
local hal_utils = require "services.hal.utils"
local utils = require "services.hal.drivers.wireless.utils"
local sc = require "fibers.utils.syscall"
local new_msg = require "bus".new_msg

local unpack = table.unpack or unpack

local DEFAULT_REPORT_PERIOD = 3600
local VALID_BANDS = { "2g", "5g" }
local VALID_HTMODES = {
    "HE20", "HE40+", "HE40-", "HE80", "HE160",
    "HT20", "HT40+", "HT40-",
    "VHT20", "VHT40+", "VHT40-", "VHT80", "VHT160"
}
local VALID_ENCRYPTIONS = {
    "none", "wep", "psk", "psk2", "psk-mixed",
    "sae", "sae-mixed", "owe", "wpa", "wpa2", "wpa3"
}
local VALID_MODES = { "ap", "sta", "adhoc", "mesh", "monitor" }
local DELETE_MARKER = true

---@class WirelessDriver
---@field ctx Context The driver's context
---@field interface string
---@field name string
---@field path string
---@field type string
---@field phy string
---@field report_period_ch Channel Channel for setting the report period of metrics
---@field phy_channel Channel Channel for sending the phy name once known
---@field interface_event_queue Queue Queue for receiving interface events
---@field client_event_queue Queue Queue for receiving client events
---@field command_q Queue Queue for receiving commands
---@field info_q Queue Queue for sending information updates
local WirelessDriver = {}
WirelessDriver.__index = WirelessDriver

local function list_is_type(value, expected_type)
    for _, t in ipairs(value) do
        if type(t) == expected_type then
            return true
        end
    end
    return false
end

local function is_list(list)
    local i = 1
    for k, _ in pairs(list) do
        if i ~= k then
            return false
        end
        i = i + 1
    end
    return true
end

-------------------------------------------------------------------------
--- WirelessDriverCapabilities -------------------------------------------

function WirelessDriver:set_report_period(ctx, period)
    op.choice(
        self.report_period_ch:put_op(period),
        ctx:done_op()
    ):perform()
    return ctx:err() == nil, ctx:err()
end

function WirelessDriver:set_channels(ctx, band, channel, htmode, channels)
    if type(band) ~= "string" or not hal_utils.is_in(band, VALID_BANDS) then
        return nil, "Invalid band, must be one of: " .. table.concat(VALID_BANDS, ", ")
    end
    if type(htmode) ~= "string" or not hal_utils.is_in(htmode, VALID_HTMODES) then
        return nil, "Invalid htmode, must be one of: " .. table.concat(VALID_HTMODES, ", ")
    end
    if channel == 'auto' then
        if channels == nil then
            return nil, "Channels must be provided when setting channel to 'auto'"
        end
        if not is_list(channels) then
            return nil, "Channels must be a list when setting channel to 'auto'"
        end
        if not (list_is_type(channels, "number") or list_is_type(channels, "string")) then
            return nil, "Channels must be a list of numbers or strings when setting channel to 'auto'"
        end
    end
    if channel ~= 'auto' and type(channel) ~= "number" and type(channel) ~= "string" then
        return nil, "Invalid channel, must be a number, string or 'auto'"
    end

    local reqs = {}

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'band', band }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'htmode', htmode }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'channel', channel }
    ))

    if channel == 'auto' then
        local cat_channels = table.concat(channels, " ")
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'wireless', self.name, 'channels', cat_channels }
        ))
    end

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return true, nil
end

function WirelessDriver:set_country(ctx, country_code)
    if type(country_code) ~= "string" or #country_code ~= 2 then
        return nil, "Invalid country code, must be a 2-letter ISO code"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'country', country_code:upper() }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end
    return true, nil
end

function WirelessDriver:set_txpower(ctx, txpower)
    if type(txpower) ~= "number" and type(txpower) ~= "string" then
        return nil, "Invalid txpower, must be a number or a string"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'txpower', txpower }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end
    return true, nil
end

function WirelessDriver:set_type(ctx, radio_type)
    if type(radio_type) ~= "string" then
        return nil, "Invalid radio type, must be a string"
    end
    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'type', radio_type }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end
    return true, nil
end

function WirelessDriver:set_enabled(ctx, enabled)
    if type(enabled) ~= 'boolean' then
        return nil, "Invalid enabled state, must be a boolean"
    end
    local disabled = enabled and '0' or '1'

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'disabled', disabled }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end
    return true, nil
end

function WirelessDriver:add_interface(ctx, ssid, encryption, password, net_interface, mode, optionals)
    if type(ssid) ~= "string" or #ssid == 0 then
        return nil, "Invalid SSID, must be a non-empty string"
    end
    if type(encryption) ~= "string" or not hal_utils.is_in(encryption, VALID_ENCRYPTIONS) then
        return nil, "Invalid encryption, must be one of: " .. table.concat(VALID_ENCRYPTIONS, ", ")
    end
    if type(password) ~= 'string' then
        return nil, "Invalid password, must be a string"
    end
    if type(net_interface) ~= "string" or #net_interface == 0 then
        return nil, "Invalid network interface, must be a non-empty string"
    end
    if not hal_utils.is_in(mode, VALID_MODES) then
        return nil, "Invalid mode, must be one of: " .. table.concat(VALID_MODES, ", ")
    end

    local wifi_interface = string.format("%s-i%s", self.name, self.iface_num)
    self.iface_num = self.iface_num + 1
    local set_sub = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', wifi_interface, 'wifi-iface' }
    ))
    local set_response, ctx_err = set_sub:next_msg_with_context(ctx)
    set_sub:unsubscribe()
    if set_response.payload and set_response.payload.err or ctx_err then
        return nil, set_response.payload.err or ctx_err
    end

    local reqs = {}

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', wifi_interface, 'device', self.name }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', wifi_interface, 'ssid', ssid }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', wifi_interface, 'encryption', encryption }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', wifi_interface, 'key', password }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', wifi_interface, 'network', net_interface }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', wifi_interface, 'mode', mode }
    ))

    if optionals.enable_steering then
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'wireless', wifi_interface, 'bss_transition', '1' }
        ))
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'wireless', wifi_interface, 'ieee80211k', '1' }
        ))
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'wireless', wifi_interface, 'rrm_neighbor_report', '1' }
        ))
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'wireless', wifi_interface, 'rrm_beacon_report', '1' }
        ))
    end

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return wifi_interface, nil
end

function WirelessDriver:delete_interface(ctx, interface)
    if type(interface) ~= "string" or #interface == 0 then
        return nil, "Invalid interface, must be a non-empty string"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'delete' },
        { 'wireless', interface }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end

    return true, nil
end

function WirelessDriver:clear_radio_config(ctx)
    local delete_req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'delete' },
        { 'wireless', self.name }
    ))
    local delete_resp, ctx_err = delete_req:next_msg_with_context(ctx)
    delete_req:unsubscribe()
    if ctx_err or (delete_resp.payload and delete_resp.payload.err) then
        return nil, ctx_err or delete_resp.payload.err
    end

    local reqs = {}
    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'wifi-device' }
    ))
    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'path', self.path }
    ))
    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'wireless', self.name, 'type', self.type }
    ))

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end
    return true, nil
end

function WirelessDriver:apply(ctx)
    local commit_sub = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'commit' },
        { 'wireless' }
    ))
    local commit_response, ctx_err = commit_sub:next_msg_with_context(ctx)
    if ctx_err or (commit_response.payload and commit_response.payload.err) then
        return nil, ctx_err or commit_response.payload.err
    end
    return true, nil
end

-------------------------------------------------------------------------
-------------------------------------------------------------------------

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
    local ubus_sub = self.conn:subscribe({ 'hal', 'capability', 'uci', '1' })
    ubus_sub:next_msg_with_context(ctx) -- Wait for initial message
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

-- pause till enabled and interface set
function WirelessDriver:_monitor_clients(ctx)
    local phy = self.phy_channel:get()
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
                    local client_phy = iface:match("^(phy%d+)")
                    if client_phy == phy then
                        log.trace(string.format(
                            "%s - %s: (%s) client %s",
                            ctx:value("service_name"),
                            ctx:value("fiber_name"),
                            iface,
                            event == "new" and "connected" or "disconnected"
                        ))
                        op.choice(
                            self.client_event_queue:put_op({
                                connected = event == "new" and true or false,
                                interface = iface,
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

local dump = require "fibers.utils.helper".dump
-- pause till enabled and interface set
function WirelessDriver:_report_metrics(ctx)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
    local report_period = DEFAULT_REPORT_PERIOD
    local next_report = sc.monotime() + report_period
    local interfaces = {}
    local phy = nil

    while not ctx:err() do
        op.choice(
            self.report_period_ch:get_op():wrap(function(period)
                next_report = next_report - report_period + period -- Adjust next_report for new period
                report_period = period
            end),
            self.interface_event_queue:get_op():wrap(function(event)
                if not phy then
                    phy = event.interface:match("^(phy%d+)")
                    if phy then self.phy_channel:put(phy) end
                end
                if event.connected then
                    if not interfaces[event.interface] then
                        interfaces[event.interface] = {}
                    end
                else
                    interfaces[event.interface] = nil
                end
            end),
            self.client_event_queue:get_op():wrap(function(event)
                if not event then return end
                if not interfaces[event.interface] then return end
                if type(event.connected) ~= "nil" then
                    self.info_q:put({
                        type = "wireless",
                        id = self.name,
                        sub_topic = { "interface", event.interface, "client", event.mac },
                        endpoints = "single",
                        info = {
                            connected = event.connected,
                            timestamp = sc.monotime()
                        }
                    })
                end
                if event.connected then
                    interfaces[event.interface][event.mac] = true
                    local client_info, client_err = iw.get_client_info(ctx, event.interface, event.mac)
                    if not client_err then
                        self.info_q:put({
                            type = "wireless",
                            id = self.name,
                            sub_topic = { "interface", event.interface, "client", event.mac },
                            endpoints = "multiple",
                            info = client_info
                        })
                    end
                else
                    interfaces[event.interface][event.mac] = nil
                end
            end),
            sleep.sleep_until_op(next_report):wrap(function()
                local client_stats = {}
                for interface, iclients in pairs(interfaces) do
                    local stats = get_iface_stats(ctx, interface)
                    if next(stats) then
                        client_stats[interface] = stats
                    end
                    for mac, _ in pairs(iclients) do
                        local client_info, client_err = iw.get_client_info(ctx, interface, mac)
                        if not client_err then
                            client_stats[interface] = client_stats[interface] or {}
                            client_stats[interface].client = client_stats[interface].client or {}
                            client_stats[interface].client[mac] = client_info
                        end
                    end
                end
                if next(client_stats) then
                    self.info_q:put({
                        type = "wireless",
                        id = self.name,
                        sub_topic = { "interface" },
                        endpoints = "multiple",
                        info = client_stats
                    })
                end
                next_report = sc.monotime() + report_period
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

function WirelessDriver:get_name()
    return self.name
end

function WirelessDriver:get_phy()
    return self.phy
end

function WirelessDriver:get_path()
    return self.path
end

--- Register and apply driver capabilities
--- @param capability_info_q Queue Queue for sending capability information updates
--- @return table capabilities The capabilities exposed by this driver
--- @return string? error Error message if capabilities couldn't be applied
function WirelessDriver:apply_capabilities(capability_info_q)
    self.info_q = capability_info_q

    -- Example of registering capabilities - customize based on driver needs
    local capabilities = {
        wireless = {
            control = hal_capabilities.new_wireless_capability(self.command_q),
            id = self.name -- unique identifier for this capability instance
        }
    }

    return capabilities, nil
end

-- This is not ideal
-- Figuring out phy from ifname should be done in init
-- but getting the associated interface from uci data is not reliable
-- due to out wifi card being one device split into two phys with the same path
-- therefore we cannot know the phy until we have an interface up event.
-- We could have an interface up event listener per driver but it is much more efficient and simple
-- to centralize it in the manager and just set the phy here when we get the event.
-- more research is needed to find a better way to assign a phy to a driver
function WirelessDriver:attach_interface(interface)
    if not self.phy then
        self.phy = interface:match("^(phy%d+)")
    end
    local interface_event = {
        connected = true,
        interface = interface
    }
    self.interface_event_queue:put(interface_event)
end

function WirelessDriver:detach_interface(interface)
    if not self.phy then
        self.phy = interface:match("^(phy%d+)")
    end
    local interface_event = {
        connected = false,
        interface = interface
    }
    self.interface_event_queue:put(interface_event)
end

--- Spawn driver fiber
--- @param conn Connection The bus connection
function WirelessDriver:spawn(conn)
    service.spawn_fiber(string.format("Wireless Main (%s)", self.name), conn, self.ctx, function(fctx)
        self:_main(fctx)
    end)
    service.spawn_fiber(string.format("Wireless Metrics Reporter (%s)", self.name), conn, self.ctx, function(fctx)
        self:_report_metrics(fctx)
    end)
    service.spawn_fiber(string.format("Wireless Client Monitor (%s)", self.name), conn, self.ctx, function(fctx)
        self:_monitor_clients(fctx)
    end)
end

function WirelessDriver:init(conn)
    self.conn = conn
    -- Delete the radio device section and rebuild it with only the name, path and type
    local ok, err = self:clear_radio_config(self.ctx)
    if not ok then
        return err
    end

    -- Delete all wifi-iface sections associated with this device
    local req = conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'foreach' },
        { 'wireless', 'wifi-iface', function(cursor, section)
            if section["device"] == self.name then
                cursor:delete('wireless', section[".name"])
            end
        end }
    ))
    local resp, ctx_err = req:next_msg_with_context(self.ctx)
    req:unsubscribe()
    -- We don't care if there was an error here, the wifi-iface sections might not exist

    -- Apply changes
    local commit_sub = conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'commit' },
        { 'wireless' }
    ))

    local commit_response, ctx_err = commit_sub:next_msg_with_context(self.ctx)
    if ctx_err or (commit_response.payload and commit_response.payload.err) then
        return ctx_err or commit_response.payload.err
    end

    return nil
end

--- Create a new driver instance
--- @param ctx Context The context for this driver
--- @return WirelessDriver The new driver instance
local function new(ctx, name, path, type)
    local self = setmetatable({}, WirelessDriver)
    self.ctx = ctx
    self.command_q = queue.new(10)
    self.name = name
    self.path = path
    self.type = type
    self.phy = nil
    self.iface_num = 0
    self.report_period_ch = channel.new()
    self.client_event_queue = queue.new(10)
    self.interface_event_queue = queue.new(10)
    self.phy_channel = channel.new()

    return self
end

return {
    new = new
}
