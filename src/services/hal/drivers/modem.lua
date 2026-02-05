-- Modem modules
local modem_types = require "services.hal.types.modem"
local attr_paths = require "services.hal.drivers.modem.attr_paths"

-- HAL modules
local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"
local external_types = require "services.hal.types.external"

-- Service modules
local log = require "services.log"

-- Fibers modules
local fibers = require "fibers"
local scope_mod = require "fibers.scope"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"

-- Other modules
local cache = require "shared.cache"

---@class Modem
---@field address ModemAddress
---@field control_ch Channel
---@field cap_emit_ch Channel
---@field scope Scope
---@field identity ModemIdentity
---@field model string
---@field model_variant string
---@field mode string
---@field initialised boolean
---@field caps_applied boolean
---@field cache Cache
local Modem = {}
Modem.__index = Modem

---- Constant Definitions ----

local DEFAULT_STOP_TIMEOUT = 5
local DEFAULT_CACHE_TIMEOUT = 10

local CONTROL_Q_LEN = 8

local ATTR_ACCESSOR = attr_paths.build_paths {
    get_modem_info = get_modem_info,
    get_modem_firmware = get_modem_firmware,
    get_sim_info = get_sim_info,
    get_home_network = get_home_network,
    get_gid1 = get_gid1,
    get_rf_band_info = get_rf_band_info,
    get_operator_info = get_operator_info,
    get_signal_info = get_signal_info,
    get_net_stats = get_net_stats,
}

local MODEL_INFO = {
    quectel = {
        -- these are ordered, as eg25gl should match before eg25g
        { mod_string = "UNKNOWN",   rev_string = "eg25gl",   model = "eg25",   model_variant = "gl" },
        { mod_string = "UNKNOWN",   rev_string = "eg25g",    model = "eg25",   model_variant = "g" },
        { mod_string = "UNKNOWN",   rev_string = "ec25e",    model = "ec25",   model_variant = "e" },
        { mod_string = "em06-e",    rev_string = "em06e",    model = "em06",   model_variant = "e" },
        { mod_string = "rm520n-gl", rev_string = "rm520ngl", model = "rm520n", model_variant = "gl" }
        -- more quectel models here
    },
    fibocom = {}
}


---- Modem Utility Functions ----

--- Emit from the modem capability
---@param emit_ch Channel
---@param imei string
---@param mode EmitMode
---@param key string
---@param data any
---@return boolean ok
---@return string? error
local function emit(emit_ch, imei, mode, key, data)
    local payload, err = hal_types.new.Emit(
        'modem',
        imei,
        mode,
        key,
        data
    )
    if not payload then
        return false, err
    end
    emit_ch:put(payload)
    return true
end

--- Emit a set of key-value pairs from the modem capability
---@param emit_ch Channel
---@param imei string
---@param kv_data table<string, any>
---@return boolean ok
---@return string? error
local function emit_kv(emit_ch, imei, kv_data)
    local all_ok = true
    local first_err = nil
    for key, value in pairs(kv_data) do
        local ok, err = emit(emit_ch, imei, 'state', key, value)
        if not ok then
            all_ok = false
            if not first_err then
                first_err = err
            end
        end
    end
    return all_ok, first_err
end

--- Utility function to throw a ControlError
---@param err string?
---@param code integer?
local function throw_error(err, code)
    if err == nil then
        err = "unknown error"
    end
    error(cap_types.new.ControlError(err, code), 2)
end

--- Emit an event.
---@param key string
---@param data any
---@return boolean ok
---@return string? error
function Modem:_emit_event(key, data)
    return emit(self.cap_emit_ch, self.identity.imei, 'event', key, data)
end

--- Emit a state.
---@param key string
---@param data any
---@return boolean ok
---@return string? error
function Modem:_emit_state(key, data)
    return emit(self.cap_emit_ch, self.identity.imei, 'state', key, data)
end

--- Emit meta information.
---@param key string
---@param data any
---@return boolean ok
---@return string? error
function Modem:_emit_meta(key, data)
    return emit(self.cap_emit_ch, self.identity.imei, 'meta', key, data)
end

--- Emit a set of key-value events.
---@param kv_data table<string, any>
---@return boolean ok
---@return string? error
function Modem:_emit_kv(kv_data)
    return emit_kv(self.cap_emit_ch, self.identity.imei, kv_data)
end

--- Emit a set of key-value states.
---@param kv_data table<string, any>
---@return boolean ok
---@return string? error
function Modem:_emit_kv_state(kv_data)
    return emit_kv(self.cap_emit_ch, self.identity.imei, kv_data)
end

--- Emit a set of key-value meta information.
---@param kv_data table<string, any>
---@return boolean ok
---@return string? error
function Modem:_emit_kv_meta(kv_data)
    return emit_kv(self.cap_emit_ch, self.identity.imei, kv_data)
end

--- Validate that a function is implemented
---@param fn any
---@return boolean is_valid
---@return string? error
local function validate_fn(fn)
    if fn == nil then
        return false, tostring(fn) .. " is unimplemented"
    end
    if type(fn) ~= "function" then
        return false, tostring(fn) .. " is not a function"
    end
    return true
end

---- Modem Capabilities ----

--- Get a modem attribute.
---@param opts ModemGetOpts?
---@return any value
---@return string? error
function Modem:get(opts)
    if opts == nil or getmetatable(opts) ~= external_types.ModemGetOpts then
        return nil, "invalid options"
    end
    local field = opts.field
    local timescale = opts.timescale or math.huge

    local accessor = ATTR_ACCESSOR[field]
    if not accessor then
        throw_error("unknown field: " .. tostring(field))
    end

    -- try to find value in cache
    local method = accessor.method
    local key = method
    if accessor.path ~= '' then
        key = key .. "." .. accessor.path
    end
    local value, err = self.cache:get(key, timescale)
    if err then throw_error(err) end

    -- if not found in cache, or stale
    if value == nil then
        local valid, validation_err = validate_fn(accessor.gettr)
        if not valid then
            return throw_error(validation_err)
        end

        local info, info_err = accessor.gettr(self.identity)
        if not info then throw_error(info_err) end
        local values = attr_paths.flatten_table(info)
        for k, v in pairs(values) do
            self.cache:set(k, v)
        end

        local ok, emit_err = self:_emit_kv_meta(values)
        if not ok then
            log.debug("Modem Driver", self.identity.imei, "emit_kv_meta error:", emit_err)
        end

        value = values[key]
    end

    if value == nil then
        throw_error("no value for field: " .. tostring(field))
    end

    return value
end

---- Long Running Fibers ----

--- Get reason and code from a ControlError
---@param control_err any
---@param verb string
local function get_reason_and_code(control_err, verb)
    if getmetatable(control_err) == cap_types.ControlError then
        ---@cast control_err ControlError
        return control_err.reason, control_err.code
    end

    local reason = "function " .. tostring(verb) .. " did not return a valid ControlError"
    return reason, 1
end

function Modem:state_monitor()
end

function Modem:control_manager()
    if self.cap_emit_ch == nil then
        log.error("Modem Driver", self.identity.imei, "control_manager: cap_emit_ch is nil")
        return
    end
    if self.control_ch == nil then
        log.error("Modem Driver", self.identity.imei, "control_manager: control_ch is nil")
        return
    end

    log.trace("Modem Driver", self.identity.imei, "control_manager: started")

    while true do
        local request, req_err = self.control_ch:get()
        if not request then
            log.error("Modem Driver", self.identity.imei, "control_manager: control_ch get error:", req_err)
            break
        end

        ---@cast request ControlRequest

        local ok, reason, code

        local fn = self[request.verb]
        local valid, validation_err = validate_fn(fn)
        if not valid then
            ok = false
            reason = "no function exists for verb: " .. tostring(validation_err)
        else
            local status, _, primary_or_val = fibers.run_scope(fn, self, request.opts)
            -- reason field holds the error in case of failure, or the return value in case of success
            if status == 'ok' then
                ok = true
                reason = primary_or_val
            else
                reason, code = get_reason_and_code(primary_or_val, request.verb)
                ok = false
            end
        end

        local reply, reply_err = hal_types.new.Reply(ok, reason, code)
        if not reply then
            log.error("Modem Driver", self.identity.imei, "control_manager: failed to create reply:", reply_err)
        else
            request.reply_ch:put(reply)
        end
    end

    log.trace("Modem Driver", self.identity.imei, "control_manager: exiting")
end

---- Driver Functions ----

local function format_ports(ports)
    local port_list = {}

    -- ports is now a comma-separated string
    if type(ports) == "string" then
        for port in ports:gmatch("[^,]+") do
            port = port:match("^%s*(.-)%s*$") -- trim whitespace
            local port_name, port_type = string.match(port, "^([%w%-]+)%s*%(([%w%-]+)%)")
            if port_name and port_type then
                if port_list[port_type] == nil then
                    port_list[port_type] = { port_name }
                else
                    table.insert(port_list[port_type], port_name)
                end
            end
        end
    end

    return port_list
end

--- Utility function to check if a string starts with a given prefix (case-insensitive)
---@param str string
---@param start string
---@return boolean
local function starts_with(str, start)
    if str == nil or start == nil then return false end
    str, start = str:lower(), start:lower()
    -- Use string.sub to get the prefix of mainString that is equal in length to startString
    return string.sub(str, 1, string.len(start)) == start
end


--- Get driver identity
---@return ModemIdentity? identity
---@return string error
function Modem:get_identity()
    if not self.initialised then
        return nil, "modem not initialised"
    end
    return self.identity, ""
end

--- Spawn driver services
---@return boolean ok
---@return string error
function Modem:start()
    if not self.initialised then
        return false, "modem not initialised"
    end
    if not self.caps_applied then
        return false, "capabilities not applied"
    end

    self.scope:spawn(self.state_monitor, self)
    self.scope:spawn(self.control_manager, self)

    return true, ""
end

--- Closes down the modem driver
---@param timeout number? Timeout in seconds
---@return boolean ok
---@return string error
function Modem:stop(timeout)
    timeout = timeout or DEFAULT_STOP_TIMEOUT
    self.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout)
    })

    if source == "timeout" then
        return false, "modem stop timeout"
    end
    return true, ""
end

--- Apply capabilities to HAL and start monitoring state
--- Modem must be initialised first
---@param emit_ch Channel
---@return Capability[]? capabilities
---@return string? error
function Modem:capabilities(emit_ch)
    if not self.initialised then
        return nil, "modem not initialised"
    end
    if self.caps_applied then
        return nil, "capabilities already applied"
    end

    self.cap_emit_ch = emit_ch

    local modem_cap, mod_cap_err = cap_types.new.ModemCapability(
        'modem',
        self.identity.imei,
        self.control_ch
    )
    if not modem_cap then
        return nil, "failed to create modem capability: " .. tostring(mod_cap_err)
    end

    self.caps_applied = true

    return { modem_cap }
end

--- Setup modem overrides and long running fibers
---@return string error
function Modem:init()
    if self.initialised then
        return "already initialised"
    end
    -- determine mode (qmi/mbim) from drivers to apply mode-specific overrides
    local drivers, drivers_err = self:get { field = 'drivers' }
    if not drivers then
        return "failed to get drivers: " .. tostring(drivers_err)
    end

    if drivers:match("qmi_wwan") then
        self.mode = 'qmi'
    elseif drivers:match("cdc_mbim") then
        self.mode = 'mbim'
    end

    assert(mode_overrides.add_mode_funcs(self))

    -- identify model to apply model-specific overrides
    local plugin, plugin_err = self:get { field = 'plugin' }
    if not plugin then
        return "failed to get plugin: " .. tostring(plugin_err)
    end

    local model, model_err = self:get { field = 'model' }
    if not model then
        return "failed to get model: " .. tostring(model_err)
    end

    local revision, revision_err = self:get { field = 'revision' }
    if not revision then
        return "failed to get revision: " .. tostring(revision_err)
    end

    for manufacturer, models in pairs(MODEL_INFO) do
        if string.match(plugin:lower(), manufacturer) then
            for _, details in ipairs(models) do
                if details.mod_string == model:lower()
                    or starts_with(revision, details.rev_string) then
                    log.info("Modem Driver", self.identity.imei,
                        "identified model as", details.model,
                        "variant", details.model_variant)
                    self.model = details.model
                    self.model_variant = details.model_variant
                    break
                end
            end
        end
    end

    model_overrides.add_model_funcs(self)

    -- obtain essential identity information
    local imei, imei_err = self:get { field = 'imei' }
    if not imei then
        return "failed to get imei: " .. tostring(imei_err)
    end

    local primary_port, primary_port_err = self:get { field = 'primary_port' }
    if not primary_port then
        return "failed to get primary_port: " .. tostring(primary_port_err)
    end

    local ports, ports_err = self:get { field = 'ports' }
    if not ports then
        return "failed to get ports: " .. tostring(ports_err)
    end

    local fmt_ports = format_ports(ports)
    if (not fmt_ports.at) or (not fmt_ports.at[1]) then
        return "no AT port found"
    end

    local device, device_err = self:get { field = 'device' }
    if not device then
        return "failed to get device: " .. tostring(device_err)
    end

    local id, id_err = modem_types.new.ModemIdentity(
        imei,
        self.address,
        primary_port,
        fmt_ports.at[1],
        device
    )

    if not id then
        return "failed to create modem identity: " .. tostring(id_err)
    end

    self.identity = id

    self.initialised = true

    return ""
end

--- Create a new Modem driver.
---@param scope Scope
---@param address ModemAddress
---@return Modem? modem
---@return string error
local function new(scope, address)
    if getmetatable(scope) ~= scope_mod.Scope then
        return nil, "invalid scope"
    end
    if type(address) ~= 'string' or address == '' then
        return nil, "invalid address"
    end

    local control_ch = channel.new(CONTROL_Q_LEN)

    return setmetatable({
        scope = scope,
        address = address,
        initialised = false,  -- modem cannot apply capabilities until initialised
        caps_applied = false, -- modem cannot start until capabilities applied
        control_ch = control_ch,
        cache = cache.new(DEFAULT_CACHE_TIMEOUT, nil, '.')
    }, Modem), ""
end

return {
    new
}
