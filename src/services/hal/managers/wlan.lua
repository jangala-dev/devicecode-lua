local context = require "fibers.context"
local op = require "fibers.op"
local queue = require "fibers.queue"
local log = require "services.log"
local wireless_driver = require "services.hal.drivers.wireless"
local service = require "service"
local new_msg = require "bus".new_msg

local WLANManagement = {}
WLANManagement.__index = WLANManagement

local function new()
    local wlan_management = {
        _wlan_devices = {},
        _wlan_add_queue = queue.new(10)
    }
    return setmetatable(wlan_management, WLANManagement)
end

function WLANManagement:_add_wlan(ctx, conn, radio_name, radio_metadata, capability_info_q)
    log.trace(string.format(
        "%s - %s: Detected WLAN of name %s",
        ctx:value("service_name"),
        ctx:value("fiber_name"),
        radio_name
    ))
    if self._wlan_devices[radio_name] then
        return
    end
    local wireless_instance = wireless_driver.new(context.with_cancel(ctx), radio_name, radio_metadata)
    local phy, err = wireless_instance:init(conn)
    if err then
        log.error(
            string.format("%s - %s: Failed to initialize wireless driver for %s: %s",
                ctx:value("service_name"),
                ctx:value("fiber_name"),
                radio_name,
                err
            )
        )
        return
    end
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
        id_field = "radioname",
        data = {
            interface = wireless_instance.interface,
            radioname = radio_name,
            devpath = radio_metadata.config.path,
        }
    }
    self._wlan_devices[radio_name] = { driver = wireless_instance, phy = phy }
    return device_event
end

function WLANManagement:_remove_wlan(ctx, radio_name, radio_metadata)
    log.trace(string.format(
        "%s - %s: Removed WLAN of name %s",
        ctx:value("service_name"),
        ctx:value("fiber_name"),
        radio_name
    ))
    local wireless_instance = self._wlan_devices[radio_name].driver
    if wireless_instance then
        wireless_instance.ctx:cancel()
        self._wlan_devices[radio_name] = nil
    end
    local device_event = {
        connected = false,
        type = 'wlan',
        id_field = "devicename",
        data = {
            interface = wireless_instance.interface,
            radioname = radio_name,
            devpath = radio_metadata.config.path
        }
    }
    return device_event
end

function WLANManagement:_get_radios(ctx, conn)
    local status_req = conn:request(new_msg(
        { 'hal', 'capability', 'ubus', '1', 'control', 'call' },
        { 'network.wireless', 'status' }
    ))
    local status_msg, ctx_err = status_req:next_msg_with_context(ctx)
    status_req:unsubscribe()
    if status_msg and status_msg.payload and status_msg.payload.err or ctx_err then
        return nil, status_msg.payload.err or ctx_err
    end
    if status_msg and status_msg.payload and status_msg.payload.result then
        return status_msg.payload.result
    end
    return nil, "Failed to get response from ubus for radios"
end

function WLANManagement:_manager(ctx, conn, device_event_q, capability_info_q)
    local ubus_sub = conn:subscribe({ 'hal', 'capability', 'ubus', '1' })
    local _, ctx_err = ubus_sub:next_msg_with_context(ctx) -- wait for ubus capability to be available
    ubus_sub:unsubscribe()
    if ctx_err then return end
    local uci_sub = conn:subscribe({ 'hal', 'capability', 'uci', '1' })
    local _, ctx_err = uci_sub:next_msg_with_context(ctx)
    uci_sub:unsubscribe()
    if ctx_err then return end
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set_restart_policy' },
        { 'wireless', { method = "immediate" }, { { 'wifi', 'reload' } } }
    ))

    -- Query initial list of wireless radios using ubus
    local radios, radio_get_err = self:_get_radios(ctx, conn)
    if radio_get_err then
        log.error(string.format(
            "%s - %s: ubus driver cannot be started, reason: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            radio_get_err
        ))
        return
    end
    for radio_name, radio_metadata in pairs(radios or {}) do
        local device_event = self:_add_wlan(
            ctx,
            conn,
            radio_name,
            radio_metadata,
            capability_info_q
        )
        device_event_q:put(device_event)
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
                local phy = data.interface:match("^(phy%d+)")
                local phy_found = false
                -- First check if we already have a driver with this phy assigned
                -- route interface event to that driver
                for _, radio in pairs(self._wlan_devices) do
                    if radio.phy == phy then
                        phy_found = true
                        if data.action == "add" then
                            radio.driver:attach_interface(data.interface)
                        else
                            radio.driver:detach_interface(data.interface)
                        end
                    end
                end
                -- If we don't have a driver with this phy assigned, it means it's a new phy
                -- We must scan all radios to find the one without a phy assigned but with an interface
                -- matching the phy of the event and assign it
                -- this is not very efficient but we don't have a better way to do it for now
                if not phy_found then
                    radios = self:_get_radios(ctx, conn)
                    for radio_name, radio_metadata in pairs(radios or {}) do
                        if radio_metadata.interfaces[1] and
                            radio_metadata.interfaces[1].ifname and
                            self._wlan_devices[radio_name] and
                            not self._wlan_devices[radio_name].phy and
                            radio_metadata.interfaces[1].ifname:match("^(phy%d+)") == phy
                        then
                            self._wlan_devices[radio_name].phy = phy
                            if data.action == "add" then
                                self._wlan_devices[radio_name].driver:attach_interface(data.interface)
                            else
                                self._wlan_devices[radio_name].driver:detach_interface(data.interface)
                            end
                        end
                    end
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
