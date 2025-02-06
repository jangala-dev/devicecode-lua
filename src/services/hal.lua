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
local log = require "log"

local hal_service = {
    name = "hal",
    modem_manager_instance = modem_manager.new()
}
hal_service.__index = hal_service

-- This will hold current available capabilities
local capabilities = {
    modem = tracker.new(),
    geo = tracker.new(),
    time = tracker.new()
}

-- Holds devices by index (for bus side access) and id (for hardware manager side access)
local devices = {
    index = {
        usb = tracker.new()
    },
    id = {
        usb = {}
    }
}

-- Core module functionality

function hal_service:spawn_config_receiver(rootctx, bus_connection)
    log.trace("HAL: Config Receiver: starting...")
    service.spawn_fiber('Config Receiver', bus_connection, rootctx, function(child_ctx)
        while not rootctx:err() do
            local sub = bus_connection:subscribe("config/hal")
            while not rootctx:err() do
                local msg, err = op.choice(
                    sub:next_msg_op(),
                    rootctx:done_op()
                ):perform()
                if err then
                    log.error(err)
                    break
                end
                if msg == nil then break end

                local config = msg.payload
                if config == nil then
                    log.error("HAL: Config Receiver: nil payload recieved")
                else
                    log.trace("HAL: Config Receiver: new config received")
                    op.choice(
                        self.modem_manager_instance.config_channel:put_op(config.modems),
                        rootctx:done_op()
                    ):perform()
                    -- sim slots/sim sets/connectors to be implemented later
                    -- (once gsm is being built out and big box .9 constraints more clear)
                    -- connector_config_channel:put(config.connectors)
                    -- sim_config_channel:put(config.sims)
                end
            end
            sub:unsubscribe()
            sleep.sleep(1) -- placeholder to prevent multiple rapid restarts
        end
    end)
end

-- HAL main control loop, handles:
--  device events (connection/disconnection)
--  capability endpoints
--  device info requests
function hal_service:spawn_control_main(ctx, bus_conn)
    service.spawn_fiber('Control', bus_conn, ctx, function(child_ctx)
        local cap_ctrl_sub, err = bus_conn:subscribe("hal/capability/+/+/control/+")
        if err ~= nil then
            log.error(err)
        end

        local dev_info_sub, err = bus_conn:subscribe("hal/device/+/+/info/+")
        if err ~= nil then
            log.error(err)
        end

        local function reply(reply_to, result, error)
            bus_conn:publish(utils.make_request_reply(reply_to, result, error))
        end

        -- capabilities requested in the topic format hal/<cap_name>/<index>/control/<endpoint_name>
        local function handle_cap_ctrl(request)
            local reply_to = request.reply_to
            local capability, instance_id, method, cap_ctrl_err = utils.parse_control_topic(request.topic)
            if cap_ctrl_err ~= nil then
                reply(reply_to, nil, cap_ctrl_err); return
            end

            local cap = capabilities[capability]
            if cap == nil then
                reply(reply_to, nil, 'capability does not exist'); return
            end

            local instance = cap:get(instance_id)
            if instance == nil then
                reply(reply_to, nil, 'capability instance does not exist'); return
            end

            local func = instance[method]
            if func == nil then
                reply(reply_to, nil, 'endpoint does not exist'); return
            end

            -- execute capability asynchronously
            fiber.spawn(function()
                -- unpack arguments to function
                local result = func(instance, request.payload)
                reply(reply_to, result, nil)
            end)
        end

        -- device info requested in the topic format /hal/device/<device_name>/<index>/info/<endpoint_name>
        local function handle_device_ctrl(request)
            local reply_to = request.reply_to
            local device_type, device_idx, info_query, dev_info_err = utils.parse_device_info_topic(request.topic)
            if dev_info_err ~= nil then
                reply(reply_to, nil, dev_info_err)
                return
            end

            local type_devices = devices.index[device_type]
            if type_devices == nil then
                reply(reply_to, nil, 'device type does not exist')
                return
            end

            local device = type_devices:get(device_idx)
            if device == nil then
                reply(reply_to, nil, 'device does not exist')
                return
            end

            local control = device.control[info_query]
            if control == nil then
                reply(reply_to, nil, 'control method does not exist')
                return
            end

            -- unpack arguments to function
            fiber.spawn(function()
                local info, info_err = control(request.payload)
                reply(reply_to, info, info_err)
            end)
        end

        -- a device event describes the device type (usb),
        -- a connection or disconnection,
        -- the indentity of the device (this is more specific to each device, no required fields),
        -- and the identifier (field needed so HAL and device manager can talk about the same device using a common key).
        -- Capabilities and device info endpoints are also supplied
        local function handle_device_event(event)
            local type_device = devices.index[event.type]
            if type_device == nil then
                log.error('Device Event: device type does not exist')
                return
            end

            local device_instance
            local device_idx
            if event.connected == nil then
                log.error('Device Event: device connected field does not exist')
                return
            end
            if event.identifier == nil then
                log.error('Device Event: device identifier does not exist')
                return
            end
            if event.connected then
                if event.identity == nil then
                    log.error('Device Event: device identity does not exist')
                    return
                end
                device_instance = {
                    identity = event.identity,
                    cap_indexes = {},
                    control = event.device_control
                }

                for cap_name, cap in pairs(event.capabilities) do
                    local capability = capabilities[cap_name]
                    if capability == nil then
                        log.error('Device Event: capability does not exist')
                    else
                        local cap_idx = capability:add(cap)
                        device_instance.cap_indexes[cap_name] = cap_idx

                        bus_conn:publish(utils.make_cap_message(cap_name, cap_idx, true))
                    end
                end

                device_idx = type_device:add(device_instance)
                devices.id[event.type][event.identifier] = device_idx
            else
                device_idx = devices.id[event.type][event.identifier]
                if device_idx == nil then
                    log.error('Device Event: removed device does not exist'); return
                end
                device_instance = type_device:get(device_idx)

                for cap_name, cap_index in pairs(device_instance.cap_indexes) do
                    local capability = capabilities[cap_name]
                    if capability == nil then
                        log.error("capability does not exist"); return
                    end
                    capability:remove(cap_index)
                    bus_conn:publish(utils.make_cap_message(cap_name, cap_index, false))
                end

                type_device:remove(device_idx)
                devices.id[event.type][event.identifier] = nil
            end

            bus_conn:publish(utils.make_device_message(event.type, device_idx, device_instance.identity, event.connected))
        end

        -- All interactions with devices and capabilities run on the same fiber
        while not ctx:err() do
            op.choice(
                cap_ctrl_sub:next_msg_op():wrap(handle_cap_ctrl),
                dev_info_sub:next_msg_op():wrap(handle_device_ctrl),
                self.modem_manager_instance.device_event_q:get_op():wrap(handle_device_event),
                ctx:done_op()
            ):perform()
        end
    end)
end

-- non blocking spawning function of HAL
function hal_service:start(bus_connection, ctx)
    log.trace("Starting HAL Service")

    -- start config reciever
    self:spawn_config_receiver(ctx, bus_connection)

    -- start main control loop
    self:spawn_control_main(ctx, bus_connection)

    self.modem_manager_instance:spawn(ctx)
end

return hal_service
