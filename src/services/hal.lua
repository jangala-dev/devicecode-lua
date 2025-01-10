local sleep = require "fibers.sleep"
local modem_manager = require "services.hal.modemcard_manager"
-- local connector = require "services.hal.connector"
local tracker = require "services.hal.device_tracker"
local utils = require "services.hal.utils"
local fiber = require "fibers.fiber"
local channel = require "fibers.channel"
local queue = require "fibers.queue"
local op = require "fibers.op"
local service = require "service"
local bus = require "bus"
local new_msg = bus.new_msg
local log = require "log"

-- We want to store events in a structure which prioritizes quick
-- event retrieval for op choices. Event removal will be called significantly less
local EventList = {}
EventList.__index = EventList
function EventList.new()
    local self = setmetatable({}, EventList)
    self.events = {}
    self.event_ids = {}
    return self
end

-- event id is a [capability_name, capability_index] pair
function EventList:add(event_id, event_op)
    -- add event to events list
    table.insert(self.events, event_op)
    table.insert(self.event_ids, event_id)
end

-- slow removal of events, but this should be called less frequently
function EventList:remove(event_id)
    local i = 0
    while i < #self.events do
        if self.event_ids[i] == event_id then
            table.remove(self.events, i)
            table.remove(self.event_ids, i)
        else
            i = i + 1
        end
    end
end

function EventList:get_events()
    return self.events
end

local hal_service = {
    name = "hal",
    capabilities = {},
    devices = {
        index = {},
        id = {}
    },
    events = EventList.new(),
    modem_manager_instance = modem_manager.new()
}
hal_service.__index = hal_service
-- HAL main control loop, handles:
--  device events (connection/disconnection)
--  capability endpoints
--  device info requests
function hal_service:control_main(ctx, bus_conn, device_event_q)
    local cap_ctrl_sub, err = bus_conn:subscribe({ 'hal', 'capability', '+', '+', 'control', '+' })
    if err ~= nil then
        log.error(err)
    end

    local dev_info_sub, err = bus_conn:subscribe({ 'hal', 'device', '+', '+', 'info', '+' })
    if err ~= nil then
        log.error(err)
    end

    -- capabilities requested in the topic format hal/<cap_name>/<index>/control/<endpoint_name>
    local function handle_cap_ctrl(request)
        local capability, instance_id, method = request.topic[3], request.topic[4], request.topic[6]

        local cap = self.capabilities[capability]
        if cap == nil then
            local msg = new_msg({ request.reply_to }, { result = nil, error = 'capability does not exist' })
            bus_conn:publish(msg)
            return
        end

        local instance = cap:get(instance_id)
        if instance == nil then
            local msg = new_msg({ request.reply_to }, { result = nil, error = 'capability instance does not exist' })
            bus_conn:publish(msg)
            return
        end

        local func = instance[method]
        if func == nil then
            local msg = new_msg({ request.reply_to }, { result = nil, error = 'endpoint does not exist' })
            bus_conn:publish(msg)
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
            bus_conn:publish(msg)
        end)
    end

    -- device info requested in the topic format /hal/device/<device_name>/<index>/info/<endpoint_name>
    local function handle_device_ctrl(request)
        local device_type, device_idx, info_query = request.topic[3], request.topic[4], request.topic[6]

        local type_devices = self.devices.index[device_type]
        if type_devices == nil then
            local msg = new_msg({ request.reply_to }, {
                result = nil,
                error = 'device type does not exist'
            })
            bus_conn:publish(msg)
            return
        end

        local device = type_devices:get(device_idx)
        if device == nil then
            local msg = new_msg({ request.reply_to }, {
                result = nil,
                error = 'device does not exist'
            })
            bus_conn:publish(msg)
            return
        end

        local control = device.control[info_query]
        if control == nil then
            local msg = new_msg({ request.reply_to }, {
                result = nil,
                error = 'control method does not exist'
            })
            bus_conn:publish(msg)
            return
        end

        -- unpack arguments to function
        fiber.spawn(function()
            local info, info_err = control(request.payload)
            local msg = new_msg({ request.reply_to }, {
                result = info,
                error = info_err
            })
            bus_conn:publish(msg)
        end)
    end

    local function handle_stream(topic, msg)
        bus_conn:publish(new_msg(topic, msg, { retained = true }))
    end

    local function handle_stream_multiple(topic, msg)
        local opts = {
            retained = true
        }
        bus_conn:publish_multiple(topic, msg, opts)
    end
    -- a device event describes the device type (usb),
    -- a connection or disconnection,
    -- the indentity of the device (this is more specific to each device, no required fields),
    -- and the identifier (field needed so HAL and device manager can talk about the same device using a common key).
    -- Capabilities and device info endpoints are also supplied
    --[[
    connected = true,
    type = 'usb',
    capabilities = nil, -- how to get capabilities?
    device_control = {},
    id_field = "port",
    data = {
        device = 'modemcard',
        port = device,
        info = driver:info()
    }
    --]]
    local function handle_device_connection_event(connection_event)
        local device_type = connection_event.type
        local device_connected = connection_event.connected
        local device_id_field = connection_event.id_field
        local device_data = connection_event.data
        local device_capabilities = connection_event.capabilities

        if device_type == nil then
            log.error('Device Event: device type field does not exist'); return
        end
        if device_connected == nil then
            log.error('Device Event: device connected field does not exist'); return
        end
        if device_id_field == nil then
            log.error('Device Event: device id field does not exist'); return
        end
        if device_data == nil then
            log.error('Device Event: device data field does not exist'); return
        end
        if device_capabilities == nil and device_connected == true then
            log.error('Device Event: device capabilities field does not exist'); return
        end
        -- local device_control = connection_event.device_control -- not used yet

        local device_id = device_data[device_id_field]

        if not self.devices.index[device_type] then
            self.devices.index[device_type] = tracker.new()
            self.devices.id[device_type] = {}
        end

        local device_tracker = self.devices.index[device_type]

        if device_connected then
            local device_instance = {
                capabilities = {},
                -- control = connection_event.device_control
            }
            for cap_name, cap in pairs(device_capabilities) do
                if not self.capabilities[cap_name] then
                    self.capabilities[cap_name] = tracker.new()
                end

                local cap_idx = self.capabilities[cap_name]:add(cap.control)
                device_instance.capabilities[cap_name] = cap_idx

                local event_names = {}
                for _, info_stream in ipairs(cap.info_streams) do
                    table.insert(event_names, info_stream.name)
                    local stream_handler = info_stream.endpoints == 'single' and handle_stream or handle_stream_multiple
                    local event_op = info_stream.channel:get_op():wrap(function(msg)
                        stream_handler(
                            { 'hal', 'capability', cap_name, cap_idx, 'info', info_stream.name },
                            msg
                        )
                    end)
                    self.events:add({ cap_name, cap_idx }, event_op)
                end

                bus_conn:publish(new_msg(
                    { 'hal', 'capability', cap_name, cap_idx },
                    {
                        connected = true,
                        type = cap_name,
                        index = cap_idx,
                        device = { type = device_type, index = device_tracker:next_index() }
                    },
                    { retained = true }
                ))
            end
            local device_index = device_tracker:add(device_instance)
            self.devices.id[device_type][device_id] = device_index

            bus_conn:publish(new_msg(
                { 'hal', 'device', device_type, device_index },
                {
                    connected = true,
                    type = device_type,
                    index = device_index,
                    identity = device_data.device
                },
                { retained = true }
            ))
        else
            local device_index = self.devices.id[device_type][device_id]
            if not device_index then
                log.error('Device Event: removed device does not exist'); return
            end
            local device_instance = device_tracker:get(device_index)

            for cap_name, cap_index in pairs(device_instance.capabilities) do
                self.events:remove({ cap_name, cap_index })
                self.capabilities[cap_name]:remove(cap_index)

                bus_conn:publish(new_msg(
                    { 'hal', 'capability', cap_name, cap_index },
                    {
                        connected = false,
                        type = cap_name,
                        index = cap_index,
                        device = { type = device_type, index = device_index }
                    },
                    { retained = true }
                ))
            end

            bus_conn:publish(new_msg(
                { 'hal', 'device', device_type, device_index },
                {
                    connected = false,
                    type = device_type,
                    index = device_index,
                    identity = device_data.device
                },
                { retained = true }
            ))

            device_tracker:remove(device_index)
            self.devices.id[device_type][device_id] = nil
        end
    end

    -- All interactions with devices and capabilities run on the same fiber
    while not ctx:err() do
        op.choice(
            cap_ctrl_sub:next_msg_op():wrap(handle_cap_ctrl),
            dev_info_sub:next_msg_op():wrap(handle_device_ctrl),
            device_event_q:get_op():wrap(handle_device_connection_event),
            ctx:done_op(),
            unpack(self.events:get_events())
        ):perform()
    end
end

-- non blocking spawning function of HAL
function hal_service:start(ctx, bus_connection)
    log.trace("Starting HAL Service")

    -- start main control loop
    local device_q = queue.new()
    service.spawn_fiber('Control', bus_connection, ctx, function(control_ctx)
        hal_service:control_main(control_ctx, bus_connection, device_q)
    end)

    -- start modem manager and detection
    self.modem_manager_instance:spawn(ctx, bus_connection, device_q)
end

return hal_service
