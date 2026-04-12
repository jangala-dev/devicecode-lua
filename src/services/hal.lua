-- HAL modules
local types = require "services.hal.types.core"
local base = require "devicecode.service_base"
local Logger = require "services.hal.logger"

-- Fibers modules
local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"

local perform = fibers.perform
local spawn = fibers.spawn

local SCHEMA_STANDARD = "devicecode.config/hal/1"

local DEFAULT_Q_LEN = 10

-- Topic helpers

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

---@alias CapabilityEntry { inst: Capability, rpc: table<string, Endpoint> }

---@class HalService
---@field name string
local HalService = {}

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

--- Checks that HAL config is valid
---@param config table
---@return boolean
---@return string error
local function validate_config(config)
    if type(config) ~= 'table' then
        return false, "config must be a table"
    end

    if config.schema ~= SCHEMA_STANDARD then
        return false, "config schema must be " .. SCHEMA_STANDARD
    end

    local managers = config.managers
    if type(managers) ~= 'table' then
        return false, "config.managers must be a table"
    end

    for key, value in pairs(managers) do
        if type(key) ~= 'string' then
            return false, "manager names must be strings"
        end
        if type(value) ~= 'table' then
            return false, "manager configs must be tables"
        end
    end

    return true, ""
end

---Spawns all HAL service long running fibers
---@param conn Connection
---@param opts any
function HalService.start(conn, opts)
    opts = opts or {}

    local svc = base.new(conn, { name = opts.name or "hal", env = opts.env })
    HalService.name = svc.name

    local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0

    local cap_emit_ch = channel.new(DEFAULT_Q_LEN)
    local dev_ev_ch = channel.new(DEFAULT_Q_LEN)
    local managers = {}
    local devices = {}
    local capabilities = {}

    local function merge_fields(a, b)
        local out = {}
        if type(a) == 'table' then
            for k, v in pairs(a) do out[k] = v end
        end
        if type(b) == 'table' then
            for k, v in pairs(b) do out[k] = v end
        end
        return out
    end

    local function obs_emitter(level, payload)
        svc:obs_log(level, payload)
    end

    ---Gets the device instance or returns nil
    ---@param class DeviceClass
    ---@param id DeviceId
    ---@return Device?
    local function get_device(class, id)
        local class_devices = devices[class]
        if not class_devices then return nil end
        return class_devices[id]
    end

    ---Sets the device instance
    ---@param class DeviceClass
    ---@param id DeviceId
    ---@param device_inst Device
    ---@return string? error
    local function set_device(class, id, device_inst)
        devices[class] = devices[class] or {}
        if devices[class][id] then
            return "device already exists"
        end
        devices[class][id] = device_inst
    end

    ---Removes the device instance
    ---@param class DeviceClass
    ---@param id DeviceId
    ---@return string? error
    local function remove_device(class, id)
        local class_devices = devices[class]
        if not class_devices or not class_devices[id] then
            return "device does not exist"
        end
        class_devices[id] = nil
    end

    ---Gets the capability instance or returns nil
    ---@param class CapabilityClass
    ---@param id CapabilityId
    ---@return CapabilityEntry?
    local function get_cap(class, id)
        local caps = capabilities[class]
        if not caps then return nil end
        return caps[id]
    end

    ---Sets the capability instance
    ---@param class CapabilityClass
    ---@param id CapabilityId
    ---@param cap_inst Capability
    ---@return string? error
    local function set_cap(class, id, cap_inst)
        capabilities[class] = capabilities[class] or {}
        if capabilities[class][id] then
            return "capability already exists"
        end
        capabilities[class][id] = { inst = cap_inst, rpc = {} }
        for offering, _ in pairs(cap_inst.offerings) do
            capabilities[class][id].rpc[offering] = conn:bind({ 'cap', class, id, 'rpc', offering })
        end
    end

    ---Removes the capability instance
    ---@param class CapabilityClass
    ---@param id CapabilityId
    ---@return string? error
    local function remove_cap(class, id)
        local caps = capabilities[class]
        if not caps or not caps[id] then
            return "capability does not exist"
        end

        for _, rpc_sub in pairs(caps[id].rpc) do
            ---@cast rpc_sub Endpoint
            rpc_sub:unbind()
        end
        caps[id] = nil
    end

    ---Adds a device and its capabilities to HAL and broadcasts event to bus
    ---@param event_type EventType
    ---@param device Device
    local function register_device(event_type, device)
        local set_err = set_device(device.class, device.id, device)
        if set_err then
            svc:obs_log('warn', {
                what = 'register_device_skipped',
                err = set_err,
                class = device.class,
                id = device.id,
            })
            return
        end

        for _, cap in ipairs(device.capabilities) do
            local cap_set_err = set_cap(cap.class, cap.id, cap)
            if cap_set_err then
                svc:obs_log('warn', {
                    what = 'register_capability_skipped',
                    err = cap_set_err,
                    class = cap.class,
                    id = cap.id,
                })
            else
                svc:obs_event('capability_registered', { class = cap.class, id = cap.id })
                conn:retain(t_cap_state(cap.class, cap.id), event_type)
                conn:retain(t_cap_meta(cap.class, cap.id), { offerings = cap.offerings })
            end
        end

        conn:retain(t_dev_meta(device.class, device.id), device.meta)
        conn:retain(t_dev_state(device.class, device.id), event_type)
        svc:obs_event('device_registered', { class = device.class, id = device.id, event_type = event_type })
    end

    ---Removes a device and its capabilities from HAL and broadcasts event to bus
    ---@param event_type EventType
    ---@param device Device
    local function unregister_device(event_type, device)
        for _, cap in ipairs(device.capabilities) do
            local cap_remove_err = remove_cap(cap.class, cap.id)
            if cap_remove_err then
                svc:obs_log('warn', {
                    what = 'remove_capability_skipped',
                    err = cap_remove_err,
                    class = cap.class,
                    id = cap.id,
                })
            else
                svc:obs_event('capability_unregistered', { class = cap.class, id = cap.id })
                conn:retain(t_cap_state(cap.class, cap.id), event_type)
                conn:unretain(t_cap_meta(cap.class, cap.id))
            end
        end

        local remove_err = remove_device(device.class, device.id)
        if remove_err then
            svc:obs_log('warn', {
                what = 'remove_device_skipped',
                err = remove_err,
                class = device.class,
                id = device.id,
            })
            return
        end

        conn:unretain(t_dev_meta(device.class, device.id))
        conn:retain(t_dev_state(device.class, device.id), event_type)
        svc:obs_event('device_unregistered', { class = device.class, id = device.id, event_type = event_type })
    end

    ---Handles running driver functions for control requests
    ---@param msg Message
    local function on_cap_ctrl(msg)
        local class, id, verb = msg.topic[2], msg.topic[3], msg.topic[5]

        if not class_valid(class) then
            svc:obs_log('warn', { what = 'invalid_cap_class', class = tostring(class) })
            return
        end

        if not id_valid(id) then
            svc:obs_log('warn', { what = 'invalid_cap_id', class = class, id = tostring(id) })
            return
        end

        local control_req, ctrl_req_err = types.new.ControlRequest(
            verb,
            msg.payload,
            channel.new()
        )
        if not control_req then
            svc:obs_log('warn', {
                what = 'control_request_invalid',
                err = tostring(ctrl_req_err),
                class = class,
                id = id,
                verb = verb,
            })
            return
        end

        local cap_entry = get_cap(class, id)
        if not cap_entry then return end

        if not cap_entry.inst.offerings[verb] then
            svc:obs_log('warn', { what = 'control_verb_unavailable', class = class, id = id, verb = verb })
            return
        end

        spawn(function()
            cap_entry.inst.control_ch:put(control_req)
            local reply, reply_err = control_req.reply_ch:get()
            if not reply then
                reply = types.new.Reply(false, reply_err)
            end
            if msg.reply_to and reply then
                local ok, pub_err = conn:publish_one(msg.reply_to, reply)
                if not ok then
                    svc:obs_log('error', {
                        what = 'control_reply_publish_failed',
                        class = class,
                        id = id,
                        verb = verb,
                        err = tostring(pub_err),
                    })
                end
            end
        end)
    end

    ---@param emit Emit
    local function on_cap_emit(emit)
        if getmetatable(emit) ~= types.Emit then
            svc:obs_log('warn', { what = 'invalid_emit_message' })
            return
        end

        local topic = { 'cap', emit.class, emit.id, emit.mode, emit.key }

        if emit.mode == 'event' then
            conn:publish(topic, emit.data)
        else
            conn:retain(topic, emit.data)
        end
    end

    ---@param device_event DeviceEvent
    local function on_device_event(device_event)
        if getmetatable(device_event) ~= types.DeviceEvent then
            svc:obs_log('warn', { what = 'invalid_device_event_message' })
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
                svc:obs_log('warn', {
                    what = 'device_instance_invalid',
                    err = tostring(dev_err),
                    class = device_event.class,
                    id = device_event.id,
                })
                return
            end
            register_device(device_event.event_type, dev_inst)
        elseif device_event.event_type == 'removed' then
            local dev_inst = get_device(device_event.class, device_event.id)
            if not dev_inst then
                svc:obs_log('warn', { what = 'device_missing', class = device_event.class, id = device_event.id })
                return
            end
            unregister_device(device_event.event_type, dev_inst)
        else
            svc:obs_log('warn', {
                what = 'device_event_unhandled',
                class = device_event.class,
                id = device_event.id,
                event_type = device_event.event_type,
            })
        end
    end

    --- Uses config to setup managers
    ---@param config table
    local function on_config(config)
        svc:obs_event('config_begin', {})

        local valid, valid_err = validate_config(config)
        if not valid then
            svc:obs_log('warn', { what = 'config_invalid', err = valid_err })
            svc:obs_event('config_end', { ok = false, err = valid_err })
            return
        end

        local managers_cfg = config.managers or {}

        for name, manager_config in pairs(managers_cfg) do
            if not managers[name] then
                local ok, manager = pcall(require, "services.hal.managers." .. name)
                if not ok then
                    svc:obs_log('error', { what = 'manager_require_failed', manager = name, err = manager })
                else
                    ---@cast manager any
                    local manager_logger = Logger.new(obs_emitter,
                        { service = svc.name, component = 'manager', manager = name })
                    local start_err = manager.start(manager_logger, dev_ev_ch, cap_emit_ch)
                    if start_err ~= "" then
                        svc:obs_log('error', { what = 'manager_start_failed', manager = name, err = start_err })
                    else
                        managers[name] = manager
                        svc:obs_event('manager_started', { manager = name })
                    end
                end
            end

            local manager = managers[name]
            if manager then
                local ok, apply_err = manager.apply_config(manager_config)
                if not ok then
                    svc:obs_log('error', { what = 'manager_apply_failed', manager = name, err = tostring(apply_err) })
                end
            end
        end

        for name, manager in pairs(managers) do
            if not managers_cfg[name] then
                managers[name] = nil
                svc:obs_event('manager_stopping', { manager = name, reason = 'removed_from_config' })
                fibers.current_scope():spawn(function()
                    manager.stop()
                end)
            end
        end

        svc:obs_event('config_end', { ok = true })
    end

    --- Creates initial utilities required for loading config which will bring up rest of HAL
    local function bootstrap()
        svc:obs_event('bootstrap_begin', {})

        local fs_manager = require "services.hal.managers.filesystem"
        ---@cast fs_manager any

        local fs_manager_err = fs_manager.start(
            Logger.new(obs_emitter, { service = svc.name, component = 'manager', manager = 'filesystem' }),
            dev_ev_ch,
            cap_emit_ch
        )
        if fs_manager_err ~= "" then
            svc:status('failed', { reason = 'filesystem manager start failed', err = fs_manager_err })
            svc:obs_log('error', {
                what = 'bootstrap_failed',
                err = fs_manager_err,
                phase = 'start_filesystem_manager',
            })
            error("HAL bootstrap failed: Failed to start filesystem manager: " .. fs_manager_err)
        end

        local ok, cfg_err = fs_manager.apply_config({
            {
                name = "config",
                root = os.getenv("DEVICECODE_CONFIG_DIR")
            }
        })

        if not ok then
            svc:status('failed', { reason = 'filesystem manager config failed', err = tostring(cfg_err) })
            svc:obs_log('error', {
                what = 'bootstrap_failed',
                err = tostring(cfg_err),
                phase = 'apply_filesystem_config',
            })
            error("HAL bootstrap failed: " .. tostring(cfg_err))
        end

        managers["filesystem"] = fs_manager
        svc:obs_event('bootstrap_end', { ok = true })
    end

    svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
    svc:obs_log('info', 'service start() entered')
    svc:status('starting')
    svc:spawn_heartbeat(heartbeat_s, 'tick')

    fibers.current_scope():finally(function()
        local scope = fibers.current_scope()
        local st, primary = scope:status()
        if st == 'failed' then
            svc:obs_log('error', { what = 'scope_failed', err = tostring(primary), status = st })
        end

        for _, class_caps in pairs(capabilities) do
            for _, cap_entry in pairs(class_caps) do
                for _, rpc_sub in pairs(cap_entry.rpc) do
                    rpc_sub:unbind()
                end
            end
        end

        svc:status('stopped', { reason = tostring(primary or 'scope_exit') })
        svc:obs_log('info', 'service stopped')
    end)

    bootstrap()
    svc:status('running')
    svc:obs_log('info', 'bootstrap successful')

    local config_sub = conn:subscribe({ 'cfg', svc.name })
    svc:obs_log('info', { what = 'subscribed', topic = 'cfg/' .. svc.name })

    while true do
        local ops = {
            cap_emit = cap_emit_ch:get_op(),
            device_event = dev_ev_ch:get_op(),
            config = config_sub:recv_op(),
        }

        local rpc_ops = {}
        for _, class in pairs(capabilities) do
            for _, cap in pairs(class) do
                for _, rpc_sub in pairs(cap.rpc) do
                    table.insert(rpc_ops, rpc_sub:recv_op())
                end
            end
        end
        if #rpc_ops > 0 then
            ops.rpc = op.choice(unpack(rpc_ops))
        end

        local manager_fault_ops = {}
        for name, manager in pairs(managers) do
            table.insert(manager_fault_ops, manager.scope:fault_op():wrap(function() return name end))
        end
        if #manager_fault_ops > 0 then
            ops.manager_fault = op.choice(unpack(manager_fault_ops))
        end

        local source, msg = perform(op.named_choice(ops))

        if source == 'rpc' then
            on_cap_ctrl(msg)
        elseif source == 'cap_emit' then
            on_cap_emit(msg)
        elseif source == 'device_event' then
            on_device_event(msg)
        elseif source == 'config' then
            local cfg_data = msg and msg.payload and msg.payload.data
            if type(cfg_data) == 'table' then
                on_config(cfg_data)
            else
                svc:obs_log('warn', { what = 'config_bad_shape', payload = msg and msg.payload })
            end
        elseif source == 'manager_fault' then
            local name = msg
            local manager = managers[name]
            if manager then
                svc:status('degraded', { reason = 'manager_fault', manager = name })
                svc:obs_log('error', { what = 'manager_fault', manager = name })
                manager.stop()
                managers[name] = nil
            end
        else
            svc:obs_log('error', { what = 'unknown_operation_source', source = tostring(source) })
        end
    end
end

return HalService
