-- Modem modules
local modem_backend_provider = require "services.hal.backends.modem.provider"

-- HAL modules
local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"
local capability_args = require "services.hal.types.capability_args"

-- Service modules
-- (logger injected via new())

-- Fibers modules
local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local cond = require "fibers.cond"
local pulse = require "fibers.pulse"

---@class Modem
---@field address ModemAddress
---@field control_ch Channel
---@field cap_emit_ch Channel
---@field scope Scope
---@field imei string
---@field model string
---@field model_variant string
---@field mode string
---@field initialised boolean
---@field caps_applied boolean
---@field state_pulse Pulse
---@field sim_inserted_pulse Pulse
---@field sim_state_ch Channel
---@field log Logger
local Modem = {}
Modem.__index = Modem

local function list_to_table(list)
    local t = {}
    for _, v in ipairs(list) do
        t[v] = true
    end
    return t
end

---- Constant Definitions ----
local D_LOG_EMITTER = false

local DEFAULT_STOP_TIMEOUT = 5
local DEFAULT_CACHE_TIMEOUT = 10
local LISTEN_TRIGGER_INTERVAL = 1

local CONTROL_Q_LEN = 8

local GET_METHODS = list_to_table {
    "imei",
    "device",
    "primary_port",
    "at_ports",
    "qmi_ports",
    -- "gps_ports", -- maybe needed for the future
    "net_ports",
    "access_techs",
    "sim",
    "drivers",
    "plugin",
    "model",
    "revision",
    "operator",
    "rx_bytes",
    "tx_bytes",
    "signal",
    "mcc",
    "mnc",
    "gid1",
    "active_band_class",
    "firmware",
    "iccid",
    "imsi"
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

--- Utility function to return a ControlError
---@param err string?
---@param code integer?
---@return boolean ok
---@return string reason
---@return integer? code
local function return_error(err, code)
    if err == nil then
        err = "unknown error"
    end
    return false, err, code
end

--- Emit an event.
---@param key string
---@param data any
---@return boolean ok
---@return string? error
function Modem:_emit_event(key, data)
    return emit(self.cap_emit_ch, self.imei, 'event', key, data)
end

--- Emit a state.
---@param key string
---@param data any
---@return boolean ok
---@return string? error
function Modem:_emit_state(key, data)
    return emit(self.cap_emit_ch, self.imei, 'state', key, data)
end

--- Emit meta information.
---@param key string
---@param data any
---@return boolean ok
---@return string? error
function Modem:_emit_meta(key, data)
    return emit(self.cap_emit_ch, self.imei, 'meta', key, data)
end

--- Validate that a function is implemented
---@param fn any
---@param verb string
---@return boolean is_valid
---@return string? error
local function validate_fn(fn, verb)
    if fn == nil then
        return false, tostring(verb) .. " is unimplemented"
    end
    if type(fn) ~= "function" then
        return false, tostring(verb) .. " is not a function"
    end
    return true
end

--- Trim the traceback from an error message
---@param err string
---@return string trimmed_error
local function trim_error(err)
    local traceback_start = err:find("\nstack traceback:")
    if traceback_start then
        return err:sub(1, traceback_start - 1)
    end
    return err
end

---- Modem Capabilities ----

--- Get a modem attribute.
---@param opts ModemGetOpts?
---@return boolean ok
---@return any reason_or_value
---@return integer? code
function Modem:get(opts)
    if opts == nil or getmetatable(opts) ~= capability_args.ModemGetOpts then
        return return_error("invalid options", 1)
    end
    local field = opts.field
    local timescale = opts.timescale

    -- Check that the field is supported
    if not GET_METHODS[field] then
        return return_error("unsupported field: " .. tostring(field), 1)
    end

    -- Call the corresponding backend function to get the value
    local get_fn = self.backend[field]
    if not get_fn then
        return return_error("field " .. tostring(field) .. " is not implemented by backend", 1)
    end
    local value, err = get_fn(self.backend, timescale)
    if err ~= "" then
        return return_error("error getting field " .. tostring(field) .. ": " .. tostring(err), 1)
    end
    return true, value
end

--- Enable the modem
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:enable()
    local ok, err = self.backend:enable()
    if not ok then
        return return_error(err, 1)
    end
    return true
end

--- Disable the modem
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:disable()
    local ok, err = self.backend:disable()
    if not ok then
        return return_error(err, 1)
    end
    return true
end

--- Reset the modem
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:reset()
    local ok, err = self.backend:reset()
    if not ok then
        return return_error(err, 1)
    end
    return true
end

--- Connect the modem
---@param opts ModemConnectOpts?
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:connect(opts)
    if opts == nil or getmetatable(opts) ~= capability_args.ModemConnectOpts then
        return return_error("invalid options", 1)
    end
    local ok, err = self.backend:connect(opts.connection_string)
    if not ok then
        return return_error(err, 1)
    end
    return true
end

--- Disconnect the modem
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:disconnect()
    local ok, err = self.backend:disconnect()
    if not ok then
        return return_error(err, 1)
    end
    return true
end

--- Inhibit the modem
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:inhibit()
    local done_ch = channel.new()

    local ok, err = self.scope:spawn(function()
        local result_ok, result_err = self.backend:inhibit()
        done_ch:put({ ok = result_ok, err = result_err })
    end)

    if not ok then
        return return_error("failed to spawn inhibit fiber: " .. tostring(err), 1)
    end

    local source, msg, primary = fibers.perform(op.named_choice {
        done = done_ch:get_op(),
        failed = self.scope:fault_op(),
    })

    if source == "done" then
        if not msg.ok then
            return return_error(msg.err, 1)
        end
        return true
    elseif source == "failed" then
        return return_error("modem inhibit failed: " .. tostring(primary), 1)
    end
    return return_error("unexpected error during modem inhibit", 1)
end

--- Uninhibit the modem
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:uninhibit()
    local ok, err = self.backend:uninhibit()
    if not ok then
        return return_error(err, 1)
    end
    return true
end

--- Start listening for a sim insertion
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:listen_for_sim()
    if self.listening_for_sim then
        return true
    end
    self.listening_for_sim = true
    local ok, err = fibers.current_scope():spawn(function()
        self:_emit_state("sim_listener", "open")

        fibers.current_scope():finally(function()
            self.listening_for_sim = false
            self:_emit_state("sim_listener", "closed")
        end)

        -- Capture pulse version before reading state to close the insertion race window.
        local last_seen = self.sim_inserted_pulse:version()
        local sim_present = self.sim_state_ch:get()

        while sim_present ~= true do
            local source, _, primary = fibers.perform(op.named_choice {
                inserted = self.sim_inserted_pulse:changed_op(last_seen),
                trigger  = sleep.sleep_op(LISTEN_TRIGGER_INTERVAL),
                failed   = self.scope:fault_op(),
            })
            if source == "inserted" then
                break
            elseif source == "trigger" then
                local trigger_ok, check_err = self.backend:trigger_sim_presence_check()
                if not trigger_ok then
                    self.log:error({ what = 'trigger_sim_check_failed', imei = self.imei, err = tostring(check_err) })
                end
            elseif source == "failed" then
                self.log:error({ what = 'listen_for_sim_scope_faulted', imei = self.imei, err = tostring(primary) })
                break
            end
        end
    end)
    if not ok then
        return return_error("listen_for_sim spawn failed: " .. tostring(err), 1)
    end
    return true
end

--- Set the signal update period
---@param opts ModemSignalUpdateOpts
---@return boolean ok
---@return string? reason
---@return integer? code
function Modem:set_signal_update_freq(opts)
    if opts == nil or getmetatable(opts) ~= capability_args.ModemSignalUpdateOpts then
        return return_error("invalid options", 1)
    end
    local ok, err = self.backend:set_signal_update_interval(opts.frequency)
    if not ok then
        return return_error(err, 1)
    end
    return true
end

function Modem:emitter()
    local timeout_buffer = 0.1
    self.log:debug({ what = 'emitter_started', imei = self.imei })

    fibers.current_scope():finally(function()
        self.log:debug({ what = 'emitter_exiting', imei = self.imei })
    end)

    local seen_version = 0
    while true do
        self.log:debug({ what = 'emitter_waiting', imei = self.imei, seen_version = seen_version })
        local new_version = self.state_pulse:changed(seen_version)
        if not new_version then
            -- Pulse was closed
            break
        end
        seen_version = new_version
        sleep.sleep(timeout_buffer) -- we want to put some buffer time in to invalidate any cache
        self.log:debug({ what = 'emitter_dispatching', imei = self.imei })

        for method, _ in pairs(GET_METHODS) do
            local opts, opts_err = capability_args.new.ModemGetOpts(method, timeout_buffer)
            if not opts then
                self.log:warn({ what = 'emitter_opts_failed', imei = self.imei, field = tostring(method), err = tostring(opts_err) })
            else
                local ok, value_or_err = self:get(opts)
                if not ok and D_LOG_EMITTER then
                    local trimmed_err = trim_error(value_or_err)
                    self.log:warn({ what = 'emitter_get_failed', imei = self.imei, field = tostring(method), err = tostring(trimmed_err) })
                else
                    local emit_ok, emit_err = self:_emit_meta(method, value_or_err)
                    if not emit_ok and D_LOG_EMITTER then
                        self.log:warn({ what = 'emitter_emit_failed', imei = self.imei, field = tostring(method), err = tostring(emit_err) })
                    end
                end
            end
        end
    end
end

function Modem:state_monitor()
    self.log:debug({ what = 'state_monitor_started', imei = self.imei })

    fibers.current_scope():finally(function()
        self.log:debug({ what = 'state_monitor_exiting', imei = self.imei })
    end)

    while true do
        local state_update, err = fibers.perform(self.backend:monitor_state_op())
        ---@cast state_update ModemStateEvent
        if err == 'Command closed' then
            self.log:error({ what = 'state_monitor_closed', imei = self.imei })
            break
        elseif err ~= "" then
            self.log:error({ what = 'state_monitor_error', imei = self.imei, err = tostring(err) })
        elseif state_update then
            self.log:debug({ what = 'state_change', imei = self.imei, from = state_update.from, to = state_update.to })
            self.state_pulse:signal() -- signal that modem state has changed
            local ok, emit_err = self:_emit_state('card', state_update)
            if not ok then
                self.log:error({ what = 'state_emit_failed', imei = self.imei, err = tostring(emit_err) })
            end
        end
    end
end

function Modem:control_manager()
    if self.cap_emit_ch == nil then
        self.log:error({ what = 'control_no_emit_ch', imei = self.imei })
        return
    end
    if self.control_ch == nil then
        self.log:error({ what = 'control_no_control_ch', imei = self.imei })
        return
    end

    self.log:debug({ what = 'control_manager_started', imei = self.imei })

    fibers.current_scope():finally(function()
        self.log:debug({ what = 'control_manager_exiting', imei = self.imei })
    end)

    while true do
        local request, req_err = self.control_ch:get()
        if not request then
            self.log:error({ what = 'control_ch_error', imei = self.imei, err = tostring(req_err) })
            break
        end

        ---@cast request ControlRequest

        local ok, reason, code

        local fn = self[request.verb]
        local valid, validation_err = validate_fn(fn, request.verb)
        if not valid then
            ok = false
            reason = validation_err
        else
            local call_ok, fn_ok, fn_reason, fn_code = pcall(fn, self, request.opts)
            if not call_ok then
                ok = false
                reason = "internal error: " .. tostring(fn_ok)
                code = 1
            else
                ok = fn_ok
                reason = fn_reason
                code = fn_code
            end
        end

        local reply, reply_err = hal_types.new.Reply(ok, reason, code)
        if not reply then
            self.log:error({ what = 'reply_create_failed', imei = self.imei, err = tostring(reply_err) })
        else
            request.reply_ch:put(reply)
        end
    end
end

function Modem:sim_lifecycle_monitor()
    self.log:debug({ what = 'sim_monitor_started', imei = self.imei })

    fibers.current_scope():finally(function()
        self.log:debug({ what = 'sim_monitor_exiting', imei = self.imei })
    end)

    local sim_present = nil
    while true do
        local source, v1, v2 = fibers.perform(op.named_choice {
            sim_change = self.backend:wait_for_sim_present_op(),
            send       = self.sim_state_ch:put_op(sim_present),
        })
        if source == "sim_change" then
            local present, err = v1, v2
            if err == "cancelled" or err == "Stream closed" or err == "Command closed" then
                self.log:debug({ what = 'sim_monitor_closed', imei = self.imei, err = tostring(err) })
                break
            elseif err ~= "" then
                self.log:error({ what = 'sim_poll_error', imei = self.imei, err = tostring(err) })
                sleep.sleep(DEFAULT_CACHE_TIMEOUT)
            elseif present then
                self.log:debug({ what = 'sim_inserted', imei = self.imei })
                sim_present = true
                self.sim_inserted_pulse:signal()
                self.state_pulse:signal()
                self:_emit_state("sim_status", "present")
            else
                self.log:debug({ what = 'sim_removed', imei = self.imei })
                self:reset() -- restart to enter failed state (cleaner than implementing a new removed state)
                sim_present = false
                self:_emit_state("sim_status", "absent")
                self.scope:cancel("modem restarting")
            end
        end
        -- source == "send": listener consumed the state, loop to offer it again
    end
end

---- Driver Functions ----

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

    self.scope:spawn(function() self:state_monitor() end)
    self.scope:spawn(function() self:control_manager() end)
    self.scope:spawn(function() self:emitter() end)
    self.scope:spawn(function() self:sim_lifecycle_monitor() end)

    -- Signal initial pulse so emitter emits the initial state
    self.state_pulse:signal()

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
        self.imei,
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

    local backend_built_sig = cond.new()

    local ok, err = self.scope:spawn(function()
        self.backend = modem_backend_provider.new(self.address)

        self.backend:start_sim_presence_monitor()
        self.backend:start_state_monitor()

        -- Get IMEI from backend
        local imei, imei_err = self.backend:imei()
        if imei_err == "" then
            self.imei = imei
        else
            error("failed to get IMEI: " .. tostring(imei_err))
        end

        backend_built_sig:signal()
    end)

    if not ok then
        return "failed to spawn modem backend fiber: " .. tostring(err)
    end

    local source, _, primary = fibers.perform(op.named_choice {
        backend_ready = backend_built_sig:wait_op(),
        failed = self.scope:fault_op()
    })

    if source == "backend_ready" then
        self.initialised = true
        return ""
    elseif source == "failed" then
        return "modem init failed: " .. tostring(primary) -- primary is the error from the faulted fiber
    else
        return "unexpected error during modem init"
    end
end

--- Create a new Modem driver.
---@param address ModemAddress
---@param logger Logger
---@return Modem? modem
---@return string error
local function new(address, logger)
    if type(address) ~= 'string' or address == '' then
        return nil, "invalid address"
    end

    local control_ch = channel.new(CONTROL_Q_LEN)

    local scope, err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(err)
    end

    -- Print out driver stack trace if scope closes on a failure
    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            logger:error({ what = 'scope_error', address = address, err = tostring(primary) })
            logger:debug({ what = 'scope_exit', address = address, status = st })
        end
        logger:debug({ what = 'stopped', address = address })
    end)

    return setmetatable({
        scope = scope,
        log = logger,
        address = address,
        initialised = false,  -- modem cannot apply capabilities until initialised
        caps_applied = false, -- modem cannot start until capabilities applied
        listening_for_sim = false,
        state_pulse = pulse.new(),
        sim_inserted_pulse = pulse.new(),
        sim_state_ch = channel.new(),
        control_ch = control_ch
    }, Modem), ""
end

return {
    new = new
}
