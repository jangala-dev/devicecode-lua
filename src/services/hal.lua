local sleep = require "fibers.sleep"
local modem_manager = require "services.hal.modem_manager"
-- local connector = require "services.hal.connector"
local tracker = require "services.hal.device_tracker"
local utils = require "services.hal.utils"
local channel = require "fibers.channel"
local queue = require "fibers.queue"
local op = require "fibers.op"
local service = require "service"
local log = require "log"

local json = require "dkjson"

-- time placeholder
-- local time = require "time"

local hal_service = {}
hal_service.__index = hal_service
hal_service.name = "hal"

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

local function config_receiver(rootctx, bus_connection, modem_config_channel)
    log.trace("HAL: Config Receiver: starting...")
    while not rootctx:err() do
        local sub = bus_connection:subscribe("config/gsm")
        while not rootctx:err() do
            local msg, err = op.choice(
                sub:next_msg_op(),
                rootctx:done_op()
            ):perform()
            if err then log.error(err) break end
            if msg == nil then break end

            local config = msg.payload
            if config == nil then
                log.error("config is nil")
            else
                log.trace("HAL: Config Receiver: new config received")
                op.choice(
                    modem_config_channel:put(config.modems),
                    rootctx:done_op()
                ):perform()
                -- connector_config_channel:put(config.connectors)
                -- sim_config_channel:put(config.sims)
            end
        end
        sub:unsubscribe()
        sleep.sleep(1) -- placeholder to prevent multiple rapid restarts
    end
end

local function control_main(ctx, bus_conn, device_event_q)
    local cap_crtl_sub, err = bus_conn:subscribe("hal/capability/+/+/control/#")
    if err ~= nil then
        log.error(err)
    end

    local dev_info_sub, err = bus_conn:subscribe("hal/device/+/+/info/#")
    if err ~= nil then
        log.error(err)
    end

    local function reply(reply_to, result, error)
        bus_conn:publish(utils.make_request_reply(reply_to, result, error))
    end

    local function handle_cap_ctrl(request)
        local reply_to = request.reply_to
        local capability, instance_id, method, cap_ctrl_err = utils.parse_control_topic(request.topic)
        if cap_ctrl_err ~= nil then reply(reply_to, nil, cap_ctrl_err); return end

        local cap = capabilities[capability]
        if cap == nil then reply(reply_to, nil, 'capability does not exist'); return end

        local instance = cap[instance_id]
        if instance == nil then reply(reply_to, nil, 'capability instance does not exist'); return end

        local func = instance.endpoints[method]
        if func == nil then reply(reply_to, nil, 'endpoint does not exist'); return end

        local result = func(instance.driver, unpack(request.payload))
        reply(reply_to, result, nil)
    end

    local function handle_device_info(request)
        local reply_to = request.reply_to
        local device_type, device_idx, info_query, dev_info_err = utils.parse_device_info_topic(request.topic)
        if dev_info_err ~= nil then reply(reply_to, nil, dev_info_err); return end

        local type_devices = devices.index[device_type]
        if type_devices == nil then reply(reply_to, nil, 'device type does not exist'); return end

        local device = type_devices:get(device_idx)
        if device == nil then reply(reply_to, nil, 'device does not exist'); return end

        local info, info_err = device:get_info(info_query)
        reply(reply_to, info, info_err)
    end

    local function handle_device_event(event)
        local type_device = devices.index[event.type]
        if type_device == nil then log.error('Device Event: device type does not exist'); return end

        local device_instance
        local device_idx
        if event.connected then
            device_instance = {
                identity = event.identity,
                driver = event.driver,
                cap_indexes = {},
                endpoints = event.device_control
            }

            for cap_name, cap in pairs(event.capabilities) do
                local capability = capabilities[cap_name]
                if capability == nil then
                    log.error('Device Event: capability does not exist')
                else
                    local cap_instance = {driver = device_instance.driver, endpoints=cap}
                    local cap_idx = capability:add(cap_instance)
                    device_instance.cap_indexes[cap_name] = cap_idx

                    bus_conn:publish(utils.make_cap_message(cap_name, cap_idx, true))
                end
            end

            device_idx = type_device:add(device_instance)
            devices.id[event.type][event.identifier] = device_idx
        else
            print(json.encode(devices.id))
            device_idx = devices.id[event.type][event.identifier]
            if device_idx == nil then log.error('Device Event: removed device does not exist'); return end
            device_instance = type_device:get(device_idx)

            for cap_name, cap_index in pairs(device_instance.cap_indexes) do
                local capability = capabilities[cap_name]
                if capability == nil then log.error("capability does not exist"); return end
                capability:remove(cap_index)
                bus_conn:publish(utils.make_cap_message(cap_name, cap_index, false))
            end

            type_device:remove(device_idx)
            devices.id[event.type][event.identifier] = nil
        end

        bus_conn:publish(utils.make_device_message(event.type, device_idx, device_instance.identity, event.connected))
    end

    while not ctx:err() do
        op.choice(
            cap_crtl_sub:next_msg_op():wrap(handle_cap_ctrl),
            dev_info_sub:next_msg_op():wrap(handle_device_info),
            device_event_q:get_op():wrap(handle_device_event),
            ctx:done_op()
        ):perform()
    end
end

function hal_service:start(bus_connection, ctx)
    print(ctx.values.service_name)
    log.trace("Starting HAL Service")

    local modem_config_channel = channel.new()
    service.spawn_fiber('Config Receiver', bus_connection, ctx, function (child_ctx)
        config_receiver(child_ctx, bus_connection, modem_config_channel)
    end)

    local modem_manager_instance = modem_manager.new()
    local device_q = queue.new()

    service.spawn_fiber('Control', bus_connection, ctx, function (child_ctx)
        control_main(child_ctx, bus_connection, device_q)
    end)

    service.spawn_fiber('Modem Card Detector', bus_connection, ctx, function (child_ctx)
        modem_manager_instance:detector(child_ctx)
    end)

    service.spawn_fiber('Modem Card Manger', bus_connection, ctx, function (child_ctx)
        modem_manager_instance:manager(child_ctx, bus_connection, device_q, modem_config_channel)
    end)
end

return hal_service