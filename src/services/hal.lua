local modem_manager = require "services.hal.managers.modemcard"
local structures = require "services.hal.structures"
local fiber = require "fibers.fiber"
local queue = require "fibers.queue"
local op = require "fibers.op"
local service = require "service"
local bus = require "bus"
local new_msg = bus.new_msg
local log = require "services.log"
local unpack = table.unpack or unpack

---@class hal_service
local hal_service = {
    name = "hal",
    capabilities = {},
    devices = {
        index = {},
        id = {}
    },
    events = structures.new_event_list(),
    device_event_q = queue.new(),
    modem_manager_instance = modem_manager.new()
}
hal_service.__index = hal_service

local function get_stream_handler(conn, endpoint_type)
    if endpoint_type == 'multiple' then
        return function(topic, msg)
            conn:publish_multiple(
                topic,
                msg,
                { retained = true }
            )
        end
    elseif endpoint_type == 'single' then
        return function(topic, msg)
            conn:publish(new_msg(
                topic,
                msg,
                { retained = true }
            ))
        end
    else
        return nil, string.format("invalid endpoint type '%s'", endpoint_type)
    end
end
---Adds a device, its capabilities and events to the service
---@param device table
---@param capabilities table
---@return table device
function hal_service:_register_device(device, capabilities)
    if not self.devices.index[device.type] then
        self.devices.index[device.type] = structures.new_tracker()
        self.devices.id[device.type] = {}
    end
    local device_tracker = self.devices.index[device.type]
    device.capabilities = {}
    for cap_name, cap in pairs(capabilities) do
        if not self.capabilities[cap_name] then
            self.capabilities[cap_name] = structures.new_tracker()
        end

        local cap_idx = self.capabilities[cap_name]:add(cap.control)
        device.capabilities[cap_name] = cap_idx

        for _, info_stream in ipairs(cap.info_streams) do
            local stream_handler, handler_err = get_stream_handler(self.conn, info_stream.endpoints)
            if handler_err then
                log.debug("Device Event: " .. handler_err)
            else
                local event_op = info_stream.channel:get_op():wrap(function(msg)
                    stream_handler(
                        { 'hal', 'capability', cap_name, cap_idx, 'info', info_stream.name },
                        msg
                    )
                end)
                self.events:add({ cap_name, cap_idx }, event_op)
            end
        end
    end
    device.index = device_tracker:add(device)
    self.devices.id[device.type][device.id] = device

    return device
end

---Removes a device, its capabilities and events from the service
---@param device table
---@return table? device
---@return string? error
function hal_service:_unregister_device(device)
    -- retrieve full device
    device = self.devices.id[device.type][device.id]
    if not device then return nil, "removed device does not exist" end

    -- remove device
    local device_tracker = self.devices.index[device.type]
    if device_tracker then
        device_tracker:remove(device.index)
    end
    self.devices.id[device.type][device.id] = nil

    -- remove capabilities and event channels
    for cap_name, cap_index in pairs(device.capabilities) do
        self.events:remove({ cap_name, cap_index })
        self.capabilities[cap_name]:remove(cap_index)
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
        device.connected = false
    end

    -- broadcast the capabilities and device connections/removals on the bus

    for cap_name, cap_index in pairs(device.capabilities) do
        self.conn:publish(new_msg(
            { 'hal', 'capability', cap_name, cap_index },
            {
                connected = device.connected,
                type = cap_name,
                index = cap_index,
                device = { type = device.type, index = device.index }
            },
            { retained = true }
        ))
    end

    self.conn:publish(new_msg(
        { 'hal', 'device', device.type, device.index },
        {
            connected = device.connected,
            type = device.type,
            index = device.index,
            -- in this case device refers to the specific type of hardware
            identity = device.data.device
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
        local msg = new_msg({ request.reply_to }, { result = nil, err = 'capability does not exist' })
        self.conn:publish(msg)
        return
    end

    local instance = cap:get(instance_id)
    if instance == nil then
        local msg = new_msg({ request.reply_to }, { result = nil, err = 'capability instance does not exist' })
        self.conn:publish(msg)
        return
    end

    local func = instance[method]
    if func == nil then
        local msg = new_msg({ request.reply_to }, { result = nil, err = 'endpoint does not exist' })
        self.conn:publish(msg)
        return
    end

    -- execute capability asynchronously
    fiber.spawn(function()
        -- unpack arguments to function
        local ret = func(instance, request.payload)
        local msg = new_msg({ request.reply_to }, {
            result = ret.result,
            err = ret.err
        })
        self.conn:publish(msg)
    end)
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
            unpack(self.events:get_events())
        ):perform()
    end
    cap_ctrl_sub:unsubscribe()
end

---Spin off all HAL service fibers
---@param ctx Context
---@param conn Connection
function hal_service:start(ctx, conn)
    log.trace("Starting HAL Service")
    self.ctx = ctx
    self.conn = conn

    -- start main control loop
    service.spawn_fiber('Control', conn, ctx, function(control_ctx)
        self:_control_main()
    end)

    -- start modem manager and detection
    self.modem_manager_instance:spawn(ctx, conn, self.device_event_q)
end

return hal_service
