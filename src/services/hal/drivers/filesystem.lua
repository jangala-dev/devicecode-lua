-- HAL modules
local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"
local cap_args = require "services.hal.types.capability_args"

-- Fibers modules
local fibers = require "fibers"
local sleep = require "fibers.sleep"
local op = require "fibers.op"
local channel = require "fibers.channel"
local file = require "fibers.io.file"
local safe = require 'coxpcall'

---@class FSDriver
---@field scope Scope
---@field roots table<string, string>
---@field control_chs table<string, Channel>
---@field cap_emit_ch Channel
---@field logger table?
---@field initialised boolean
---@field caps_applied boolean
local FSDriver = {}
FSDriver.__index = FSDriver

---- Constant Definitions ----

local DEFAULT_STOP_TIMEOUT = 5
local CONTROL_Q_LEN = 8

local function dlog(self, level, payload)
    if self.logger and self.logger[level] then
        self.logger[level](self.logger, payload)
    end
end

---- Utility Functions ----

--- Return a ControlError
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

--- Emit from the filesystem capability
---@param emit_ch Channel
---@param root_name string
---@param mode EmitMode
---@param key string
---@param data any
---@return boolean ok
---@return string? error
local function emit(emit_ch, root_name, mode, key, data)
    local payload, err = hal_types.new.Emit(
        'fs',
        root_name,
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

---- Filesystem Capabilities ----

--- Read a file from a root
---@param root_name string
---@param opts FilesystemReadOpts?
---@return boolean ok
---@return string reason_or_content
---@return integer? code
function FSDriver:read(root_name, opts)
    if opts == nil or getmetatable(opts) ~= cap_args.FilesystemReadOpts then
        return return_error("invalid options", 1)
    end

    local filename = opts.filename
    if filename == nil then
        return return_error("missing filename", 1)
    end

    local root_path = self.roots[root_name]
    if not root_path then
        return return_error("unknown root: " .. tostring(root_name), 1)
    end

    local full_path = root_path .. "/" .. filename

    -- Open file using fibers stream
    local f, open_err = file.open(full_path, "r")
    if not f then
        return return_error("failed to open file " .. full_path .. ": " .. tostring(open_err), 1)
    end

    local content, read_err = f:read_all()
    local _, close_err = f:close()

    if not content then
        return return_error("failed to read file " .. full_path .. ": " .. tostring(read_err), 1)
    end

    if close_err then
        dlog(self, 'warn', {
            what = 'read_close_warning',
            root = root_name,
            filename = filename,
            err = tostring(close_err),
        })
    end

    -- Emit success event
    local ok, emit_err = emit(self.cap_emit_ch, root_name, 'event', 'read_success', {
        filename = filename
    })
    if not ok then
        dlog(self, 'warn', {
            what = 'read_success_emit_failed',
            root = root_name,
            filename = filename,
            err = tostring(emit_err),
        })
    end

    return true, content
end

--- Write a file to a root
---@param root_name string
---@param opts FilesystemWriteOpts?
---@return boolean ok
---@return string? reason
---@return integer? code
function FSDriver:write(root_name, opts)
    if opts == nil or getmetatable(opts) ~= cap_args.FilesystemWriteOpts then
        return return_error("invalid options", 1)
    end

    local filename = opts.filename
    if filename == nil then
        return return_error("missing filename", 1)
    end

    local root_path = self.roots[root_name]
    if not root_path then
        return return_error("unknown root: " .. tostring(root_name), 1)
    end

    local full_path = root_path .. "/" .. filename

    -- Open file using fibers stream
    local f, open_err = file.open(full_path, "w")
    if not f then
        return return_error("failed to open file for writing: " .. tostring(open_err), 1)
    end

    local ok, write_err = f:write(opts.data)
    local _, close_err = f:close()

    if not ok then
        return return_error("failed to write file: " .. tostring(write_err), 1)
    end

    if close_err then
        dlog(self, 'warn', {
            what = 'write_close_warning',
            root = root_name,
            filename = filename,
            err = tostring(close_err),
        })
    end

    -- Emit success event
    local ok_emit, emit_err = emit(self.cap_emit_ch, root_name, 'event', 'write_success', {
        filename = filename
    })
    if not ok_emit then
        dlog(self, 'warn', {
            what = 'write_success_emit_failed',
            root = root_name,
            filename = filename,
            err = tostring(emit_err),
        })
    end

    return true
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

---- Long Running Fibers ----

function FSDriver:control_manager()
    if self.cap_emit_ch == nil then
        dlog(self, 'error', { what = 'control_manager_missing_cap_emit_channel' })
        return
    end

    dlog(self, 'debug', { what = 'control_manager_started' })

    fibers.current_scope():finally(function()
        dlog(self, 'debug', { what = 'control_manager_exiting' })
    end)

    while true do
        -- Build named choice over all root control channels
        local choice_arms = {}
        for root_name, control_ch in pairs(self.control_chs) do
            choice_arms[root_name] = control_ch:get_op()
        end

        -- Wait for a request from any root's control channel
        local root_name, request, req_err = fibers.perform(op.named_choice(choice_arms))

        if not request then
            dlog(self, 'error', { what = 'control_channel_get_failed', err = tostring(req_err) })
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
            local call_ok, fn_ok, fn_reason, fn_code = safe.pcall(fn, self, root_name, request.opts)
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
            dlog(self, 'error', { what = 'reply_create_failed', err = tostring(reply_err) })
        else
            request.reply_ch:put(reply)
        end
    end
end

---- Driver Functions ----

--- Spawn filesystem driver services
---@return boolean ok
---@return string error
function FSDriver:start()
    if not self.initialised then
        return false, "filesystem not initialised"
    end
    if not self.caps_applied then
        return false, "capabilities not applied"
    end

    self.scope:spawn(function() self:control_manager() end)

    return true, ""
end

--- Closes down the filesystem driver
---@param timeout number? Timeout in seconds
---@return boolean ok
---@return string error
function FSDriver:stop(timeout)
    timeout = timeout or DEFAULT_STOP_TIMEOUT
    self.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout)
    })

    if source == "timeout" then
        return false, "filesystem stop timeout"
    end
    return true, ""
end

--- Apply capabilities to HAL and start monitoring state
--- Filesystem must be initialised first
---@param emit_ch Channel
---@return Capability[]? capabilities
---@return string error
function FSDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "filesystem not initialised"
    end
    if self.caps_applied then
        return nil, "capabilities already applied"
    end

    self.cap_emit_ch = emit_ch

    local caps = {}

    for cap_name, _ in pairs(self.roots) do
        local control_ch = self.control_chs[cap_name]
        local cap, cap_err = cap_types.new.FilesystemCapability(cap_name, control_ch)
        if not cap then
            return nil, "failed to create capability for root " .. cap_name .. ": " .. tostring(cap_err)
        end

        table.insert(caps, cap)
    end

    self.caps_applied = true

    return caps, ""
end

--- Initialize the filesystem driver
--- Creates missing root directories and validates configuration
---@return string error
function FSDriver:init()
    if self.initialised then
        return "already initialised"
    end

    -- Validate roots
    if type(self.roots) ~= 'table' or next(self.roots) == nil then
        return "roots must be a non-empty table"
    end

    -- Create control channels for each root and create missing directories
    for root_name, root_path in pairs(self.roots) do
        if type(root_path) ~= 'string' or root_path == '' then
            return "root path for " .. tostring(root_name) .. " must be a non-empty string"
        end

        -- Create control channel for this root
        self.control_chs[root_name] = channel.new(CONTROL_Q_LEN)

        -- Create missing root directory
        local ok, mkdir_err = file.mkdir_p(root_path)
        if not ok then
            local err_msg = "failed to create root directory " .. tostring(root_name) ..
                            " at " .. tostring(root_path) .. ": " .. tostring(mkdir_err)
            return err_msg
        end

        dlog(self, 'debug', { what = 'root_ready', root = root_name, path = root_path })
    end

    self.initialised = true
    return ""
end

--- Create a new filesystem driver
---@param roots table<string, string> A mapping of root names to their paths
---@param logger table?
---@return FSDriver?
---@return string error
local function new(roots, logger)
    local self = setmetatable({}, FSDriver)
    local scope, sc_err = fibers.current_scope():child()
    if not scope then return nil, sc_err end

    self.scope = scope
    self.roots = roots or {}
    self.control_chs = {}
    self.logger = logger
    self.initialised = false
    self.caps_applied = false

    return self, ""
end

return {
    new = new,
}
