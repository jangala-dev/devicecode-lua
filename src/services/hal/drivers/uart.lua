-- HAL modules
local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"
local external_types = require "services.hal.types.external"

-- Service modules
local log = require "services.log"

-- Fibers modules
local fibers = require "fibers"
local sleep = require "fibers.sleep"
local op = require "fibers.op"
local channel = require "fibers.channel"
local file = require "fibers.io.file"

---@class UARTDriver
---@field name string Port name (e.g. "uart0")
---@field path string Device path (e.g. "/dev/ttyAMA0")
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel
---@field filestream any? Open file handle when port is open, nil otherwise
---@field is_open boolean
---@field initialised boolean
---@field caps_applied boolean
local UARTDriver = {}
UARTDriver.__index = UARTDriver

---- Constant Definitions ----

local DEFAULT_STOP_TIMEOUT = 5
local CONTROL_Q_LEN = 8

---- Utility Functions ----

--- Return a ControlError triple.
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

--- Emit from the UART capability.
---@param emit_ch Channel
---@param name string
---@param mode EmitMode
---@param key string
---@param data any
---@return boolean ok
---@return string? error
local function emit(emit_ch, name, mode, key, data)
    local payload, err = hal_types.new.Emit(
        'uart',
        name,
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

---- UART Capabilities ----

--- Open the serial port.
--- OpenWrt kernel defaults are used for port settings.
---@param opts UARTOpenOpts?
---@return boolean ok
---@return string? reason
---@return integer? code
function UARTDriver:open(opts)
    if opts == nil or getmetatable(opts) ~= external_types.UARTOpenOpts then
        return return_error("invalid options", 1)
    end

    if self.is_open then
        return return_error("port already open", 1)
    end

    local mode
    if opts.read and opts.write then
        mode = "r+"
    elseif opts.read then
        mode = "r"
    else
        mode = "w"
    end

    local filestream, open_err = file.open(self.path, mode)
    if not filestream then
        return return_error("failed to open port: " .. tostring(open_err), 1)
    end

    self.filestream = filestream
    self.is_open = true

    -- Only spawn a reader when the port was opened for reading
    if opts.read then
        self.scope:spawn(function() self:read_loop() end)
    end

    log.trace("UART Driver", self.name, "opened at", self.path)
    return true
end

--- Close the serial port.
---@return boolean ok
---@return string? reason
---@return integer? code
function UARTDriver:close()
    if not self.is_open then
        return return_error("port not open", 1)
    end

    local _, close_err = self.filestream:close()
    if close_err then
        log.warn("UART Driver", self.name, "warning on close:", close_err)
    end

    self.filestream = nil
    self.is_open = false

    -- Emit a closed status event so consumers know the port is no longer available
    local ok, emit_err = emit(self.cap_emit_ch, self.name, 'state', 'status', 'closed')
    if not ok then
        log.warn("UART Driver", self.name, "failed to emit close status:", emit_err)
    end

    log.trace("UART Driver", self.name, "closed")
    return true
end

--- Write data to the serial port.
---@param opts UARTWriteOpts?
---@return boolean ok
---@return string? reason
---@return integer? code
function UARTDriver:write(opts)
    if opts == nil or getmetatable(opts) ~= external_types.UARTWriteOpts then
        return return_error("invalid options", 1)
    end

    if not self.is_open then
        return return_error("port not open", 1)
    end

    local ok, write_err = self.filestream:write(opts.data)
    if not ok then
        -- Close the port on write failure — the connection is considered broken
        log.error("UART Driver", self.name, "write error, closing port:", write_err)
        self:close()
        return return_error("write failed: " .. tostring(write_err), 1)
    end

    return true
end

---- Long Running Fibers ----

--- Read lines from the open filestream and emit them as 'out' events.
--- Runs until the filestream returns an error or EOF (i.e. port closed).
function UARTDriver:read_loop()
    log.trace("UART Driver", self.name, "read_loop: started")

    fibers.current_scope():finally(function()
        log.trace("UART Driver", self.name, "read_loop: exiting")
    end)

    while true do
        local line, err = self.filestream:read_line()

        if err then
            log.error("UART Driver", self.name, "read_loop: read error:", err)
            break
        end

        if line == nil then
            -- EOF — port was closed
            break
        end

        local ok, emit_err = emit(self.cap_emit_ch, self.name, 'event', 'out', line)
        if not ok then
            log.warn("UART Driver", self.name, "read_loop: failed to emit line:", emit_err)
        end
    end
end

--- Dispatch control requests arriving on control_ch.
--- Each request carries a verb ('open', 'close', 'write'), opts, and a reply
--- channel. Requests are handled one at a time so port state at each step is
--- deterministic. 'close' takes no opts; all others expect a typed opts struct.
function UARTDriver:control_manager()
    log.trace("UART Driver", self.name, "control_manager: started")

    fibers.current_scope():finally(function()
        log.trace("UART Driver", self.name, "control_manager: exiting")
    end)

    while true do
        -- Block until a control request arrives
        local request, req_err = self.control_ch:get()

        if not request then
            log.error("UART Driver", self.name, "control_manager: channel get error:", req_err)
            break
        end

        ---@cast request ControlRequest

        local ok, reason, code

        if request.verb == 'open' then
            ok, reason, code = self:open(request.opts)
        elseif request.verb == 'close' then
            ok, reason, code = self:close()
        elseif request.verb == 'write' then
            ok, reason, code = self:write(request.opts)
        else
            ok = false
            reason = "unknown verb: " .. tostring(request.verb)
            code = 1
        end

        local reply, reply_err = hal_types.new.Reply(ok, reason, code)
        if not reply then
            log.error("UART Driver", self.name, "control_manager: failed to create reply:", reply_err)
        else
            request.reply_ch:put(reply)
        end
    end
end

---- Driver Functions ----

--- Spawn UART driver services.
---@return boolean ok
---@return string error
function UARTDriver:start()
    if not self.initialised then
        return false, "uart driver not initialised"
    end
    if not self.caps_applied then
        return false, "capabilities not applied"
    end

    self.scope:spawn(function() self:control_manager() end)

    return true, ""
end

--- Closes down the UART driver.
---@param timeout number? Timeout in seconds
---@return boolean ok
---@return string error
function UARTDriver:stop(timeout)
    timeout = timeout or DEFAULT_STOP_TIMEOUT
    self.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout)
    })

    if source == "timeout" then
        return false, "uart driver stop timeout"
    end
    return true, ""
end

--- Apply capabilities to HAL.
--- Driver must be initialised first.
---@param emit_ch Channel
---@return Capability[]? capabilities
---@return string error
function UARTDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "uart driver not initialised"
    end
    if self.caps_applied then
        return nil, "capabilities already applied"
    end

    self.cap_emit_ch = emit_ch
    self.control_ch = channel.new(CONTROL_Q_LEN)

    local cap, cap_err = cap_types.new.UARTCapability(self.name, self.control_ch)
    if not cap then
        return nil, "failed to create UART capability: " .. tostring(cap_err)
    end

    self.caps_applied = true

    return { cap }, ""
end

--- Initialise the UART driver.
--- Validates name and path before marking the driver as ready for capabilities
--- and start.
---@return string error
function UARTDriver:init()
    if self.initialised then
        return "already initialised"
    end

    if type(self.name) ~= 'string' or self.name == '' then
        return "name must be a non-empty string"
    end

    if type(self.path) ~= 'string' or self.path == '' then
        return "path must be a non-empty string"
    end

    self.initialised = true
    return ""
end

--- Return the device path for this driver.
--- Used by the manager to diff config changes.
---@return string
function UARTDriver:get_path()
    return self.path
end

--- Create a new UART driver.
---@param name string Port name (e.g. "uart0")
---@param path string Device path (e.g. "/dev/ttyAMA0")
---@return UARTDriver? driver
---@return string error
local function new(name, path)
    local self = setmetatable({}, UARTDriver)

    local scope, sc_err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create scope: " .. tostring(sc_err)
    end

    -- Log any unexpected scope failure to aid diagnostics
    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("UART Driver [%s]: scope failed - %s"):format(tostring(name), tostring(primary)))
        end
        log.trace(("UART Driver [%s]: scope closed"):format(tostring(name)))
    end)

    self.name         = name
    self.path         = path
    self.scope        = scope
    self.is_open      = false
    self.initialised  = false
    self.caps_applied = false

    return self, ""
end

return {
    new = new,
}
