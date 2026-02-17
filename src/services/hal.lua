-- HAL modules
local types = require "services.hal.types.core"

-- Fibers modules
local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"

local perform = fibers.perform
local spawn = fibers.spawn
local now = fibers.now

-- General modules
local log = require "services.log"

local DEFAULT_Q_LEN = 10

-- Topic helpers

---@param class DeviceClass
---@param id DeviceId
---@return string[] topic
local function t_dev_event(class, id)
    return { 'dev', class, id, 'event' }
end

---@param class DeviceClass
---@param id DeviceId
---@return string[] topic
local function t_dev_meta(class, id)
    return { 'dev', class, id, 'meta' }
end

---@param class DeviceClass
---@param id DeviceId
---@return string[] topic
local function t_dev_state(class, id)
    return { 'dev', class, id, 'state' }
end

---@param class CapabilityClass
---@param id CapabilityId
---@return string[] topic
local function t_cap_meta(class, id)
    return { 'cap', class, id, 'meta' }
end

---@param class CapabilityClass
---@param id CapabilityId
---@return string[] topic
local function t_cap_state(class, id)
    return { 'cap', class, id, 'state' }
end

---@class HalService
---@field name string
---@field cap_emit_ch Channel
---@field dev_ev_ch Channel
---@field managers table<string, Manager>
---@field devices table<string, Device>
---@field capabilities table<string, Capability>
local HalService = {
    cap_emit_ch = channel.new(DEFAULT_Q_LEN), -- capability emits of state, meta or events
    dev_ev_ch = channel.new(DEFAULT_Q_LEN),   -- manager emits of device events (added/removed)
    managers = {},
    devices = {},
    capabilities = {},
    rpc_subs = {}
}

---Publishes the HAL service status
---@param conn Connection
---@param name string
---@param state string
---@param extra table?
local function publish_status(conn, name, state, extra)
    local payload = { state = state, ts = now() }
    if type(extra) == 'table' then
        for k, v in pairs(extra) do payload[k] = v end
    end
    conn:retain({ 'svc', name, 'status' }, payload)
end

---Validates class string
---@param class CapabilityClass|DeviceClass
---@return boolean
local function class_valid(class)
    return type(class) == 'string' and class ~= ''
end

---Validates id string or number
---@param id CapabilityId|DeviceId
---@return boolean
local function id_valid(id)
    return (type(id) == 'string' and id ~= '') or (type(id) == 'number' and id >= 0)
end

---Gets the device instance or returns nil
---@param class DeviceClass
---@param id DeviceId
---@return Device?
local function get_device(class, id)
    local devices = HalService.devices[class]
    if not devices then return nil end
    return devices[id]
end

---Sets the device instance
---@param class DeviceClass
---@param id DeviceId
---@param device_inst Device
---@return string? error
local function set_device(class, id, device_inst)
    HalService.devices[class] = HalService.devices[class] or {}
    if HalService.devices[class][id] then
        return "device already exists"
    end
    HalService.devices[class][id] = device_inst
end

---Removes the device instance
---@param class DeviceClass
---@param id DeviceId
---@return string? error
local function remove_device(class, id)
    local devices = HalService.devices[class]
    if not devices or not devices[id] then
        return "device does not exist"
    end
    HalService.devices[class][id] = nil
end

---Gets the capability instance or returns nil
---@param class CapabilityClass
---@param id CapabilityId
---@return Capability?
local function get_cap(class, id)
    local caps = HalService.capabilities[class]
    if not caps then return nil end
    return caps[id]
end

---Sets the capability instance
---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
---@param cap_inst Capability
---@return string? error
local function set_cap(conn, class, id, cap_inst)
    HalService.capabilities[class] = HalService.capabilities[class] or {}
    if HalService.capabilities[class][id] then
        return "capability already exists"
    end
    HalService.capabilities[class][id] = { inst = cap_inst, rpc = {} }
    for offering, _ in pairs(cap_inst.offerings) do
        print(class, id, offering)
        HalService.capabilities[class][id].rpc[offering] = conn:bind({ 'cap', class, id, 'rpc', offering })
    end
end

---Removes the capability instance
---@param class CapabilityClass
---@param id CapabilityId
---@return string? error
local function remove_cap(class, id)
    local caps = HalService.capabilities[class]
    if not caps or not caps[id] then
        return "capability does not exist"
    end
    for _, rpc_sub in pairs(HalService.capabilities[class][id].rpc) do
        ---@cast rpc_sub Endpoint
        rpc_sub:unbind()
    end
    HalService.capabilities[class][id] = nil
end

---Handles running driver functions for control requests
---@param conn Connection
---@param msg Message
local function on_cap_ctrl(conn, msg)
    local class, id, verb = msg.topic[2], msg.topic[3], msg.topic[5]

    if not class_valid(class) then
        log.debug(HalService.name, "- invalid class")
        return
    end

    if not id_valid(id) then
        log.debug(HalService.name, "- invalid id")
        return
    end

    local control_req, ctrl_req_err = types.new.ControlRequest(
        verb,
        msg.payload,
        channel.new()
    )
    if not control_req then
        log.debug(HalService.name, "-", ctrl_req_err)
        return
    end

    local cap_inst = get_cap(class, id)
    if not cap_inst then return end -- could be a capability owned by another service

    if not cap_inst.offerings[verb] then
        log.debug(HalService.name, "- capability", class, "does not offer verb:", verb)
        return
    end

    spawn(function()
        cap_inst.control_ch:put(control_req)
        local reply, reply_err = control_req.reply_ch:get()
        if not reply then
            reply = types.new.Reply(false, reply_err)
        end
        if msg.reply_to then
            local ok, pub_err = conn:publish_one(msg.reply_to, reply)
            if not ok then
                log.debug(HalService.name, "-", pub_err)
            end
        end
    end)
end

---@param conn Connection
---@param emit Emit
local function on_cap_emit(conn, emit)
    if getmetatable(emit) ~= types.Emit then
        log.debug(HalService.name, "- invalid emit message")
        return
    end
    conn:publish({ 'cap', emit.class, emit.id, emit.mode, emit.key }, emit.data)
end

---Adds a device and its capabilities to HAL and broadcasts event to bus
---@param conn Connection
---@param event_type EventType
---@param device Device
local function register_device(conn, event_type, device)
    local set_err = set_device(device.class, device.id, device)
    if set_err then
        log.debug(HalService.name, "-", set_err)
        return
    end

    for _, cap in ipairs(device.capabilities) do
        local cap_set_err = set_cap(conn, cap.class, cap.id, cap)
        if cap_set_err then
            log.debug(HalService.name, "-", cap_set_err)
        else
            conn:retain(t_cap_state(cap.class, cap.id), event_type)
            conn:retain(t_cap_meta(cap.class, cap.id), { offerings = cap.offerings })
        end
    end

    conn:retain(t_dev_meta(device.class, device.id), device.meta)
    conn:retain(t_dev_state(device.class, device.id), event_type)
end

---Removes a device and its capabilities from HAL and broadcasts event to bus
---@param conn Connection
---@param event_type EventType
---@param device Device
local function unregister_device(conn, event_type, device)
    for _, cap in ipairs(device.capabilities) do
        local cap_remove_err = remove_cap(cap.class, cap.id)
        if cap_remove_err then
            log.debug(HalService.name, "-", cap_remove_err)
        else
            conn:retain(t_cap_state(cap.class, cap.id), event_type)
            conn:unretain(t_cap_meta(cap.class, cap.id))
        end
    end

    local remove_err = remove_device(device.class, device.id)
    if remove_err then
        log.debug(HalService.name, "-", remove_err)
        return
    end
    conn:unretain(t_dev_meta(device.class, device.id))
    conn:retain(t_dev_state(device.class, device.id), event_type)
end

---@param conn Connection
---@param device_event DeviceEvent
local function on_device_event(conn, device_event)
    if getmetatable(device_event) ~= types.DeviceEvent then
        log.debug(HalService.name, "- invalid device event message")
        return
    end

    if device_event.event_type == 'added' then
        local dev_inst, dev_err = types.new.Device(
            device_event.class,
            device_event.id,
            device_event.meta,
            device_event.capabilities
        )
        if not dev_inst then
            log.debug(HalService.name, "-", dev_err)
            return
        end
        register_device(conn, device_event.event_type, dev_inst)
    elseif device_event.event_type == 'removed' then
        local dev_inst = get_device(device_event.class, device_event.id)
        if not dev_inst then
            log.debug(HalService.name, "- device does not exist")
            return
        end
        unregister_device(conn, device_event.event_type, dev_inst)
    else
        log.debug(HalService.name,
            "- unhandled device event type for ",
            device_event.class,
            device_event.id,
            device_event.event_type
        )
        return
    end
end

---Spawns all HAL service long running fibers
---@param conn Connection
---@param opts any
function HalService.start(conn, opts)
    log.trace("HAL: starting")
    HalService.name = opts.name or "hal"
    publish_status(conn, HalService.name, "starting")

    fibers.current_scope():finally(function()
        local scope = fibers.current_scope()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("HAL: error - %s"):format(tostring(primary)))
            log.trace("HAL: scope exiting with status", st)
        end
        publish_status(conn, HalService.name, "stopped")
        log.trace("HAL: stopped")
    end)

    local modemcard_manager = require "services.hal.managers.modemcard"
    HalService.managers.modemcard = modemcard_manager

    for name, manager in pairs(HalService.managers) do
        local err = manager.start(HalService.dev_ev_ch, HalService.cap_emit_ch)
        if err ~= "" then
            log.error("HAL failed to start " .. name .. " manager", err)
        end
    end

    publish_status(conn, HalService.name, "running")

    while true do
        local rpc_ops = {} -- choice needs at least 1 op to aviod fatal error

        for _, class in pairs(HalService.capabilities) do
            for _, cap in pairs(class) do
                for _, rpc_sub in pairs(cap.rpc) do
                    table.insert(rpc_ops, rpc_sub:recv_op())
                end
            end
        end

        local manager_fault_ops = {}

        for name, manager in pairs(HalService.managers) do
            table.insert(manager_fault_ops, manager.scope:fault_op():wrap(function () return name end))
        end

        local ops = {
            cap_emit = HalService.cap_emit_ch:get_op(),
            device_event = HalService.dev_ev_ch:get_op()
        }

        if #rpc_ops > 0 then
            ops.rpc = op.choice(unpack(rpc_ops))
        end

        if #manager_fault_ops > 0 then
            ops.modem_manager_fault = op.choice(unpack(manager_fault_ops))
        end

        local source, msg = perform(op.named_choice(ops))

        if source == 'rpc' then
            on_cap_ctrl(conn, msg)
        elseif source == 'cap_emit' then
            on_cap_emit(conn, msg)
        elseif source == 'device_event' then
            on_device_event(conn, msg)
        elseif source == 'modem_manager_fault' then
            local name = msg
            local manager = HalService.managers[name]
            if manager then
                log.error("HAL: modem manager fault detected")
                manager.stop()
                HalService.managers[name] = nil
            end
        else
            log.error("HAL: unknown operation source:", source)
        end
    end
end

return HalService
