local context = require "fibers.context"
local op = require "fibers.op"
local log = require "services.log"
local wireless_driver = require "services.hal.drivers.wireless"
local service = require "service"
local new_msg = require "bus".new_msg

local WLANManagement = {}
WLANManagement.__index = WLANManagement

local function new()
    local wlan_management = {
        _wlan_devices = {}
    }
    return setmetatable(wlan_management, WLANManagement)
end

function WLANManagement:_add_wlan(ctx, conn, event, capability_info_q)
    log.trace(string.format(
        "%s - %s: Detected WLAN of name %s",
        ctx:value("service_name"),
        ctx:value("fiber_name"),
        event.devicename
    ))
    if self._wlan_devices[event.devicename] then
        self._wlan_devices[event.devicename].ctx:cancel()
        self._wlan_devices[event.devicename] = nil
    end
    local wireless_instance = wireless_driver.new(context.with_cancel(ctx), event.interface)
    local capabilities, cap_err = wireless_instance:apply_capabilities(capability_info_q)
    if cap_err then
        log.error(cap_err)
        return
    end
    wireless_instance:spawn(conn)
    local device_event = {
        connected = true,
        type = 'wlan',
        capabilities = capabilities,
        device_control = {},
        id_field = "devicename",
        data = {
            devicename = event.devicename,
            devpath = event.devpath,
            devtype = event.devtype,
            interface = event.interface
        }
    }
    self._wlan_devices[event.devicename] = wireless_instance
    return device_event
end

function WLANManagement:_remove_wlan(ctx, event)
    log.trace(string.format(
        "%s - %s: Removed WLAN of name %s",
        ctx:value("service_name"),
        ctx:value("fiber_name"),
        event.devicename
    ))
    local wireless_instance = self._wlan_devices[event.devicename]
    if wireless_instance then
        wireless_instance.ctx:cancel()
        self._wlan_devices[event.devicename] = nil
    end
    local device_event = {
        connected = false,
        type = 'wlan',
        id_field = "devicename",
        data = {
            devicename = event.devicename,
            devpath = event.devpath,
            devtype = event.devtype,
            interface = event.interface
        }
    }
    return device_event
end

function WLANManagement:_manager(ctx, conn, device_event_q, capability_info_q)
    local ubus_sub = conn:subscribe({ 'hal', 'capability', 'ubus', '1' })
    local _, ctx_err = ubus_sub:next_msg_with_context(ctx) -- wait for ubus capability to be available
    ubus_sub:unsubscribe()
    if ctx_err then return end
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    -- Query initial list of wireless radios using ubus
    local status_req = conn:request(new_msg(
        { 'hal', 'capability', 'ubus', '1', 'control', 'call' },
        { 'network.wireless', 'status' }
    ))
    local status_msg, ctx_err = status_req:next_msg_with_context(ctx) -- THIS IS NOT RETURNING, INVESTIGATE UBUS CALL
    status_req:unsubscribe()
    if status_msg and status_msg.payload and status_msg.payload.err or ctx_err then
        log.error(string.format(
            "%s - %s: failed to get initial wireless status: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            status_msg.payload.err or ctx_err
        ))
        return
    end
    if status_msg and status_msg.payload and status_msg.payload.result then
        for _, radio in pairs(status_msg.payload.result) do
            if not radio.disabled then
                local event = {
                    devicename = radio.interfaces[1].ifname,
                    devpath = "/devices/platform/" .. radio.config.path,
                    devtype = "wlan",
                    interface = radio.interfaces[1].ifname
                }
                local device_event = self:_add_wlan(ctx, conn, event, capability_info_q)
                if device_event then
                    device_event_q:put(device_event)
                end
            end
        end
    else
        log.error(string.format(
            "%s - %s: failed to get initial wireless status: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            status_err
        ))
    end

    local hotplug_req = conn:request(new_msg(
        { 'hal', 'capability', 'ubus', '1', 'control', 'listen' },
        { 'hotplug.net' }
    ))

    local msg, ctx_err = hotplug_req:next_msg_with_context(ctx)
    hotplug_req:unsubscribe()
    if ctx_err or msg and msg.payload and msg.payload.err then
        log.error(string.format(
            "%s - %s: ubus driver cannot be started, reason: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            ctx_err or msg.payload.err
        ))
        return
    end

    local stream_id = msg.payload.result.stream_id

    local hotplug_sub = conn:subscribe(
        { 'hal', 'capability', 'ubus', '1', 'info', 'stream', stream_id }
    )
    local stream_end_sub = conn:subscribe(
        { 'hal', 'capability', 'ubus', '1', 'info', 'stream', stream_id, 'closed' }
    )

    local process_ended = false

    while not process_ended and not ctx:err() do
        op.choice(
            hotplug_sub:next_msg_op():wrap(function(msg)
                local event = msg.payload
                if not event then return end
                local data = event['hotplug.net']
                if data.devtype ~= 'wlan' then return end
                local device_event = nil
                if data.action == "add" then
                    device_event = self:_add_wlan(ctx, conn, data, capability_info_q)
                elseif data.action == "remove" then
                    device_event = self:_remove_wlan(ctx, data)
                end
                if device_event then
                    device_event_q:put(device_event)
                end
            end),
            stream_end_sub:next_msg_op():wrap(function(msg)
                process_ended = msg.payload
            end),
            ctx:done_op():wrap(function()
                conn:publish(new_msg(
                    { 'hal', 'capability', 'ubus', '1', 'control', 'stop_stream' },
                    { stream_id }
                ))
            end)
        ):perform()
    end
    hotplug_sub:unsubscribe()
    stream_end_sub:unsubscribe()

    log.trace(string.format(
        "%s - %s: Stopping",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

function WLANManagement:spawn(ctx, conn, device_event_q, capability_info_q)
    service.spawn_fiber("WLAN Manager", conn, ctx, function(fctx)
        self:_manager(fctx, conn, device_event_q, capability_info_q)
    end)
end

return { new = new }
