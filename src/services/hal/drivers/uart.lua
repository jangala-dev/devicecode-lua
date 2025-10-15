-- driver.lua
local queue = require "fibers.queue"
local fiber = require "fibers.fiber"
local op = require "fibers.op"
local file = require "fibers.stream.file"
local service = require "service"
local hal_capabilities = require "services.hal.hal_capabilities"
local sc = require "fibers.utils.syscall"
local log = require "services.log"
local unpack = table.unpack or unpack -- Lua 5.2 compatibility

---@class Driver
---@field ctx Context
---@field address string
---@field command_q Queue
---@field refresh_rate_channel Channel
local Driver = {}
Driver.__index = Driver

--[[
-- Helper function to set baudrate on a serial port
function M.set_baudrate(fd, baudrate)
    -- Convert baudrate to termios constant
    local baud_const = M.BAUDRATES[baudrate]
    if not baud_const then
        return nil, "Unsupported baudrate: " .. tostring(baudrate)
    end

    -- Get current termios settings
    local termios = ffi.new("struct termios")
    if ffi.C.tcgetattr(fd, termios) ~= 0 then
        local errno = ffi.errno()
        return nil, "Failed to get terminal attributes: " .. M.strerror(errno), errno
    end

    -- Set input and output baud rates
    if ffi.C.cfsetispeed(termios, baud_const) ~= 0 or
       ffi.C.cfsetospeed(termios, baud_const) ~= 0 then
        local errno = ffi.errno()
        return nil, "Failed to set baudrate: " .. M.strerror(errno), errno
    end

    -- Apply settings
    if ffi.C.tcsetattr(fd, M.TCSANOW, termios) ~= 0 then
        local errno = ffi.errno()
        return nil, "Failed to apply terminal settings: " .. M.strerror(errno), errno
    end

    return true
end

-- Helper function to get current baudrate
function M.get_baudrate(fd)
    local termios = ffi.new("struct termios")
    if ffi.C.tcgetattr(fd, termios) ~= 0 then
        local errno = ffi.errno()
        return nil, "Failed to get terminal attributes: " .. M.strerror(errno), errno
    end

    local speed = ffi.C.cfgetospeed(termios)

    -- Find baudrate by constant
    for rate, const in pairs(M.BAUDRATES) do
        if const == speed then
            return rate
        end
    end

    return nil, "Unknown baudrate constant: " .. tostring(speed)
end

-- Serial port setup helper function
function M.setup_serial_port(fd, baudrate, databits, parity, stopbits, flow_control)
    local termios = ffi.new("struct termios")
    if ffi.C.tcgetattr(fd, termios) ~= 0 then
        local errno = ffi.errno()
        return nil, "Failed to get terminal attributes: " .. M.strerror(errno), errno
    end

    -- Clear all settings
    termios.c_cflag = 0
    termios.c_iflag = 0
    termios.c_oflag = 0
    termios.c_lflag = 0

    -- Set baudrate
    local baud_const = M.BAUDRATES[baudrate]
    if not baud_const then
        return nil, "Unsupported baudrate: " .. tostring(baudrate)
    end

    if ffi.C.cfsetispeed(termios, baud_const) ~= 0 or
       ffi.C.cfsetospeed(termios, baud_const) ~= 0 then
        local errno = ffi.errno()
        return nil, "Failed to set baudrate: " .. M.strerror(errno), errno
    end

    -- Apply settings (other settings like databits, parity, etc. could be added here)
    if ffi.C.tcsetattr(fd, M.TCSANOW, termios) ~= 0 then
        local errno = ffi.errno()
        return nil, "Failed to apply terminal settings: " .. M.strerror(errno), errno
    end

    return true
end
--]]


------------------------------------------------------------------ Capability functions
---------------------------------------------------------------------------------------
function Driver:open(ctx, opts)
    print("BAUDRATE:", opts.baudrate)
    if self.is_open then
        return nil, "Port already open"
    end
    local baudrate = opts.baudrate or 115200
    local open_mode = ""
    if opts.read and opts.write then
        open_mode = "r+"
    elseif opts.read then
        open_mode = "r"
    elseif opts.write then
        open_mode = "w"
    else
        return nil, "Either read or write must be true"
    end

    local filestream, err = file.open(self.port, open_mode)
    local fd = filestream and filestream.io and filestream.io.fd or nil
    if not fd then
        log.error(string.format("Failed to open serial port %s: %s", self.name, err))
        return nil, err
    end
    if err then
        log.error(string.format("Failed to open serial port %s: %s", self.name, err))
        return nil, err
    end

    local termios = sc.new_termios()
    local ok, err = sc.tcgetattr(fd, termios)
    if not ok then
        log.error(string.format("Failed to get terminal attributes for %s: %s", self.name, err))
        file.close(fd)
        return nil, err
    end

    local baud_const = sc.BAUDRATES[baudrate]
    if not baud_const then
        log.error(string.format("Unsupported baudrate: %s", tostring(baudrate)))
        file.close(fd)
        return nil, "Unsupported baudrate"
    end

    ok, err = sc.cfsetispeed(termios, baud_const)
    if not ok then
        log.error(string.format("Failed to set input speed for %s: %s", self.name, err))
        file.close(fd)
        return nil, err
    end

    ok, err = sc.cfsetospeed(termios, baud_const)
    if not ok then
        log.error(string.format("Failed to set output speed for %s: %s", self.name, err))
        file.close(fd)
        return nil, err
    end

    ok, err = sc.tcsetattr(fd, sc.TCSANOW, termios)
    if not ok then
        log.error(string.format("Failed to apply terminal settings for %s: %s", self.name, err))
        file.close(fd)
        return nil, err
    end

    self.filestream = filestream
    self.is_open = true
    print("Opened serial port", self.name, "at", baudrate)
    return true, nil
end

function Driver:close(ctx)
    if not self.is_open then
        return nil, "Port not open"
    end
    self.filestream:close()
    self.filestream = nil
    self.is_open = false
    self.info_q:put({
        type = "uart",
        id = self.name,
        sub_topic = { "status" },
        endpoints = "single",
        info = "closed"
    })
    return true, nil
end

function Driver:write(ctx, data)
    if not self.is_open then
        return nil, "Port not open"
    end

    local bytes_written, err = op.choice(
        self.filestream:write_op(data),
        ctx:done_op():wrap(function()
            return nil, "Driver cancelled"
        end)
    ):perform()
    if err then
        self:close(ctx)
    end
    return bytes_written, err
end

-- unlike other drivers, capabilities here block the main loop to provide
-- deterministic order of execution
function Driver:_handle_capability(ctx, req)
    local command = req.command
    local args = req.args or {}
    local ret_ch = req.return_channel

    if type(ret_ch) == 'nil' then return end

    if type(command) == "nil" then
        ret_ch:put({
            result = nil,
            err = 'No command was provided'
        })
        return
    end

    local func = self[command]
    if type(func) ~= "function" then
        ret_ch:put({
            result = nil,
            err = "Command does not exist"
        })
        return
    end

    local res, err = func(self, ctx, unpack(args))
    fiber.spawn(function()
        op.choice(
            ret_ch:put_op({
                res = res,
                err = err
            }),
            ctx:done_op()
        ):perform()
    end)
end

function Driver:_main(ctx)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    while not ctx:err() do
        local ops = {
            self.capability_q:get_op():wrap(function(req)
                self:_handle_capability(ctx, req)
            end),
            ctx:done_op()
        }
        if self.is_open then
            table.insert(ops, self.filestream:read_line_op():wrap(function(line, _, err)
                if (not line) or err then
                    self:close(ctx)
                    return
                end
                self.info_q:put({
                    type = "uart",
                    id = self.name,
                    sub_topic = { "out" },
                    endpoints = "single",
                    info = line
                })
            end))
        end
        op.choice(unpack(ops)):perform()
    end
    self:close(ctx)
    log.trace(string.format(
        "%s - %s: Exiting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

function Driver:get_port()
    return self.port
end

---returns a list of control and info capabilities for the modem
---@return table
function Driver:apply_capabilities(capability_info_q)
    self.info_q = capability_info_q
    local capabilities = {}
    capabilities.uart = {
        control = hal_capabilities.new_serial_capability(self.capability_q),
        id = self.name
    }
    return capabilities
end

---@param conn Connection
function Driver:spawn(conn)
    service.spawn_fiber('Serial Main (' .. self.name .. ')', conn, self.ctx, function(fctx)
        self:_main(fctx)
    end)
end

local function new(ctx, name, port)
    local self = setmetatable({}, Driver)
    self.ctx = ctx
    self.name = name
    self.port = port
    self.capability_q = queue.new(10)
    self.filestream = nil
    -- Other initial properties
    return self
end

return {
    new = new
}
