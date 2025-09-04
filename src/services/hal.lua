local modem_manager = require "services.hal.managers.modemcard"
local ubus_manager = require "services.hal.managers.ubus"
local uci_manager = require "services.hal.managers.uci"
local wlan_managaer = require "services.hal.managers.wlan"
local fiber = require "fibers.fiber"
local queue = require "fibers.queue"
local op = require "fibers.op"
local service = require "service"
local new_msg = require("bus").new_msg
local log = require "services.log"
local unpack = table.unpack or unpack

---@class hal_service
local hal_service = {
    name = "hal",
    capabilities = {},
    devices = {},
    capability_info_q = queue.new(50),
    device_event_q = queue.new(10),
    modem_manager_instance = modem_manager.new(),
    ubus_manager_instance = ubus_manager.new(),
    uci_manager_instance = uci_manager.new(),
    wlan_manager_instance = wlan_managaer.new()
}
hal_service.__index = hal_service

---Adds a device, its capabilities and events to the service
---@param device table
---@param capabilities table
---@return table device
---@return string? error
function hal_service:_register_device(device, capabilities)
    if not self.devices[device.type] then
        self.devices[device.type] = {}
    end
    device.capabilities = {}
    for cap_name, cap in pairs(capabilities) do
        if not cap.id then
            log.error(string.format(
                "Device Event: capability '%s' for device '%s' with id '%s' does not have an id",
                cap_name, device.type, device.id
            ))
        else
            if not self.capabilities[cap_name] then
                self.capabilities[cap_name] = {}
            end

            if self.capabilities[cap_name][cap.id] then
                log.debug(string.format(
                    "Device Event: capability '%s' with id '%s' already exists, overwriting",
                    cap_name, cap.id
                ))
            end
            self.capabilities[cap_name][cap.id] = cap.control
            device.capabilities[cap_name] = cap.id
        end
    end
    if self.devices[device.type][device.id] then
        log.debug(string.format(
            "Device Event: device '%s' with id '%s' already exists, overwriting",
            device.type, device.id
        ))
    end
    self.devices[device.type][device.id] = device

    return device
end

---Removes a device, its capabilities and events from the service
---@param device table
---@return table? device
---@return string? error
function hal_service:_unregister_device(device)
    -- retrieve full device
    device = self.devices[device.type] and self.devices[device.type][device.id]
    if not device then return nil, "removed device does not exist" end
    self.devices[device.type][device.id] = nil

    -- remove capabilities and event channels
    for cap_name, cap_id in pairs(device.capabilities) do
        self.capabilities[cap_name][cap_id] = nil
        self.conn:publish(new_msg(
            { 'hal', 'capability', cap_name, cap_id, '#' },
            nil,
            { retained = true }
        ))
    end

    return device
end

---Checks that all required fields are present in the connection event
---@param connection_event table
---@return boolean
---@return string? error
local function connection_event_valid(connection_event)
    if not connection_event.type then
        return false, "missing device type"
    end
    if connection_event.connected == nil then
        return false, "missing device connected status"
    end
    if not connection_event.id_field then
        return false, "missing device id field"
    end
    if not connection_event.data then
        return false, "missing device data"
    end
    if connection_event.connected and not connection_event.capabilities then
        return false, "missing device capabilities"
    end
    return true
end

---Handles device connection and disconnection events
---@param connection_event table
function hal_service:_handle_device_connection_event(connection_event)
    local valid, err = connection_event_valid(connection_event)
    if not valid then
        log.error("Device Event: " .. err)
        return
    end

    local device_capabilities = connection_event.capabilities

    -- create a basic device instance, this will be built
    -- up further in the register and unregister functions
    local device = {
        type = connection_event.type,
        connected = connection_event.connected,
        id = connection_event.data[connection_event.id_field],
        data = connection_event.data
    }

    if device.connected then
        local full_device, register_err = self:_register_device(device, device_capabilities)
        if register_err then
            log.error("Device Event: " .. register_err)
            return
        end
        device = full_device
    else
        local full_device, unregister_err = self:_unregister_device(device)
        if unregister_err then
            log.error("Device Event: " .. unregister_err)
            return
        end
        device = full_device
        -- since we now have the original device instance, change to disconnected
        device.connected = false
    end

    -- broadcast the capabilities and device connections/removals on the bus

    for cap_name, cap_id in pairs(device.capabilities) do
        self.conn:publish(new_msg(
            { 'hal', 'capability', cap_name, cap_id },
            {
                connected = device.connected,
                type = cap_name,
                index = cap_id,
                device = { type = device.type, index = device.id }
            },
            { retained = true }
        ))
    end

    self.conn:publish(new_msg(
        { 'hal', 'device', device.type, device.id },
        {
            connected = device.connected,
            type = device.type,
            index = device.id,
            -- in this case device refers to the specific type of hardware
            identity = device.data.device,
            metadata = device.data
        },
        { retained = true }
    ))
end

---Uses device driver to execute control commands
---@param request table
function hal_service:_handle_capability_control(request)
    local capability, instance_id, method = request.topic[3], request.topic[4], request.topic[6]

    local cap = self.capabilities[capability]
    if cap == nil then
        if request.reply_to then
            local msg = new_msg({ request.reply_to }, { result = nil, err = 'capability does not exist' })
            self.conn:publish(msg)
        end
        return
    end

    local instance = cap[instance_id]
    if instance == nil then
        if request.reply_to then
            local msg = new_msg({ request.reply_to }, { result = nil, err = 'capability instance does not exist' })
            self.conn:publish(msg)
        end
        return
    end

    local func = instance[method]
    if func == nil then
        if request.reply_to then
            local msg = new_msg({ request.reply_to }, { result = nil, err = 'endpoint does not exist' })
            self.conn:publish(msg)
        end
        return
    end

    -- execute capability asynchronously
    fiber.spawn(function()
        -- unpack arguments to function
        local ret = func(instance, request.payload)
        if request.reply_to then
            local msg = new_msg({ request.reply_to }, {
                result = ret.result,
                err = ret.err
            })
            self.conn:publish(msg)
        end
    end)
end

function hal_service:_handle_capbility_info(data)
    if not data then return end

    if not data.type then
        log.error(string.format(
            '%s - %s: Capability info message does not have a type field',
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name")
        ))
        return
    end

    if not data.id then
        log.error(string.format(
            '%s - %s: Capability info message does not have an id field',
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name")
        ))
        return
    end

    if not data.endpoints then
        log.error(string.format(
            '%s - %s: Capability info message must define an endpoints field ("single" or "multiple")',
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name")
        ))
        return
    end

    local sub_topic = data.sub_topic or {}
    local topic = { 'hal', 'capability', data.type, data.id, 'info', unpack(sub_topic) }

    if data.endpoints == 'single' then
        self.conn:publish(new_msg(
            topic,
            data.info,
            { retained = true }
        ))
    elseif data.endpoints == 'multiple' then
        self.conn:publish_multiple(
            topic,
            data.info,
            { retained = true }
        )
    end
end

---Handles capability and device control, and connection events
function hal_service:_control_main()
    local cap_ctrl_sub, cap_sub_err = self.conn:subscribe({ 'hal', 'capability', '+', '+', 'control', '+' })
    if cap_sub_err ~= nil then
        log.error(string.format(
            '%s - %s: Failed to subscribe to capability control topic, reason: %s',
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name"),
            cap_sub_err
        ))
        return
    end

    -- All interactions with devices and capabilities run on the same fiber
    while not self.ctx:err() do
        op.choice(
            cap_ctrl_sub:next_msg_op():wrap(function(msg) self:_handle_capability_control(msg) end),
            self.device_event_q:get_op():wrap(function(msg) self:_handle_device_connection_event(msg) end),
            self.ctx:done_op(),
            self.capability_info_q:get_op():wrap(function(msg) self:_handle_capbility_info(msg) end)
        ):perform()
    end
    cap_ctrl_sub:unsubscribe()
end

---Spin off all HAL service fibers
---@param ctx Context
---@param conn Connection
function hal_service:start(ctx, conn)
    log.trace(string.format(
        "%s: Starting",
        ctx:value("service_name")
    ))
    self.ctx = ctx
    self.conn = conn

    -- start main control loop
    service.spawn_fiber('Control', conn, ctx, function(control_ctx)
        self:_control_main()
    end)

    -- start managers
    self.modem_manager_instance:spawn(ctx, conn, self.device_event_q, self.capability_info_q)
    self.ubus_manager_instance:spawn(ctx, conn, self.device_event_q, self.capability_info_q)
    self.uci_manager_instance:spawn(ctx, conn, self.device_event_q, self.capability_info_q)
    self.wlan_manager_instance:spawn(ctx, conn, self.device_event_q, self.capability_info_q)
end

return hal_service
