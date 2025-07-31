local queue = require "fibers.queue"
local op = require "fibers.op"
local fiber = require "fibers.fiber"
local exec = require "fibers.exec"
local context = require "fibers.context"
local sc = require "fibers.utils.syscall"
local log = require "services.log"
local hal_capabilities = require "services.hal.hal_capabilities"
local service = require "service"
local uuid = require "uuid"
local unpack = table.unpack or unpack
local cjson = require "cjson.safe"

local STRING_SEPARATOR = string.char(31)

local UBus = {}
UBus.__index = UBus

function UBus.new(ctx)
    local ubus = { ctx = ctx, cap_control_q = queue.new(10) }
    return setmetatable(ubus, UBus)
end

local streams = {
    by_key = {},
    by_id = {}
}

local function validate_paths(paths)
    for _, path in ipairs(paths) do
        if type(path) ~= 'string' or path == '' then
            return false, "Invalid path: " .. tostring(path)
        end
    end
    return true, nil
end

local function sort_alphabetically(str1, str2)
    return str1:lower() < str2:lower()
end

--- --------------------------------------------------------------------------------
--- ubus capabilities
--- --------------------------------------------------------------------------------

function UBus:list(ctx)
    local result, err = exec.command_context(ctx, 'ubus', 'list'):output()
    if err then
        return result, err
    end

    local list = {}
    for line in result:gmatch("[^\r\n]+") do
        table.insert(list, line)
    end
    return list, nil
end

function UBus:call(ctx, path, method, ...)
    local args = { ... }
    local result, err = exec.command_context(ctx, 'ubus', 'call', path, method, unpack(args)):output()
    if err then
        return nil, "Failed to call ubus method: " .. method .. ": " .. err
    end

    local data, decode_err = cjson.decode(result)
    if decode_err then
        return nil, "Failed to decode ubus call output: " .. decode_err
    end

    return data, nil
end

--- Cancel a stream if it exists and has no users left
--- @param stream_id string
--- @return boolean success
--- @return string? err
function UBus:stop_stream(ctx, stream_id)
    local stream = streams.by_id[stream_id]
    if not stream then
        return false, "Stream not found"
    end

    stream.users = stream.users - 1
    if stream.users > 0 then
        return true, nil
    end

    stream.cancel_fn()
    streams.by_key[stream.key] = nil
    streams.by_id[stream_id] = nil

    log.trace(string.format(
        "%s - %s: Stopped ubus stream %s",
        self.ctx:value("service_name"),
        self.ctx:value("fiber_name"),
        stream_id
    ))

    fiber.spawn(function()
        op.choice(
            self.info_q:put_op({
                type = "ubus",
                id = "1",
                sub_topic = { "stream", stream_id, "closed" },
                endpoints = "single",
                info = true
            }),
            ctx:done_op()
        ):perform()
    end)

    return true, nil
end

--- Create a streaming endpoint that outputs listen events given for paths,
--- or return existing stream if it already exists.
--- @param ctx Context
--- @param ... string[]
--- @return table? stream_info
--- @return string? err
function UBus:listen(ctx, ...)
    local paths = { ... }
    local valid, err = validate_paths(paths)
    if not valid then
        return nil, err
    end
    -- sort paths alphabetically to ensure consistent key generation
    table.sort(paths, sort_alphabetically)
    table.insert(paths, 1, 'listen')
    local path_key = table.concat(paths, STRING_SEPARATOR)
    if streams.by_key[path_key] then
        local stream_info = streams.by_id[streams.by_key[path_key]]
        stream_info.users = stream_info.users + 1
        return { stream_id = streams.by_key[path_key] }, nil
    end

    local stream_id = uuid.new()
    local stream_ctx, cancel = context.with_cancel(ctx)

    streams.by_key[path_key] = stream_id
    streams.by_id[stream_id] = {
        key = path_key,
        cancel_fn = cancel,
        users = 1,
    }

    fiber.spawn(function()
        log.trace(string.format(
            "%s - %s: Starting ubus listen command for stream %s with paths: %s",
            stream_ctx:value("service_name"),
            stream_ctx:value("fiber_name"),
            stream_id,
            table.concat(paths, ", ")
        ))

        local cmd = exec.command('ubus', 'listen', unpack(paths))
        cmd:setprdeathsig(sc.SIGKILL)
        local stdout = cmd:stdout_pipe()
        if not stdout then
            log.error(string.format(
                "%s - %s: Failed to create stdout pipe for ubus listen command",
                stream_ctx:value("service_name"),
                stream_ctx:value("fiber_name")
            ))
            op.choice(
                self.cap_control_q:put_op({
                    command = "stop_stream",
                    args = { stream_id },
                    return_channel = { put = function() end }
                }),
                stream_ctx:done_op()
            ):perform()
            return
        end

        local cmd_err = cmd:start()
        if cmd_err then
            log.error(string.format(
                "%s - %s: Failed to start ubus listen command: %s",
                stream_ctx:value("service_name"),
                stream_ctx:value("fiber_name"),
                cmd_err
            ))
            cmd:wait()
            stdout:close()
            op.choice(
                self.cap_control_q:put_op({
                    command = "stop_stream",
                    args = { stream_id },
                    return_channel = { put = function() end }
                }),
                stream_ctx:done_op()
            ):perform()
            return
        end

        while not stream_ctx:err() do
            op.choice(
                stdout:read_line_op():wrap(function(line)
                    if not line then
                        stream_ctx:cancel("command finished")
                        return
                    end
                    local data, decode_err = cjson.decode(line)
                    if decode_err then
                        log.error(string.format(
                            "%s - %s: Failed to decode ubus listen data: %s, reason: %s",
                            stream_ctx:value("service_name"),
                            stream_ctx:vselfalue("fiber_name"),
                            tostring(line),
                            decode_err
                        ))
                        return
                    end

                    op.choice(
                        self.info_q:put_op({
                            type = "ubus",
                            id = "1",
                            sub_topic = { "stream", stream_id },
                            endpoints = "single",
                            info = data
                        }),
                        stream_ctx:done_op()
                    ):perform()
                end),
                stream_ctx:done_op():wrap(function()
                    cmd:kill()
                end)
            ):perform()
        end
        cmd:wait()
        stdout:close()

        -- cleanup on command stop
        op.choice(
            self.cap_control_q:put_op({
                command = "stop_stream",
                args = { stream_id },
                return_channel = { put = function() end }
            }),
            stream_ctx:done_op()
        ):perform()

        log.trace(string.format(
            "%s - %s: Ubus listen command finished for stream %s",
            stream_ctx:value("service_name"),
            stream_ctx:value("fiber_name"),
            stream_id
        ))
    end)

    return { stream_id = stream_id }, nil
end

function UBus:send(ctx, type, message)
    local result, err = exec.command_context(ctx, 'ubus', 'send', type, cjson.encode(message)):output()
    if err then
        return result, "Failed to send ubus message: " .. err
    end
    return result, nil
end

-- ubus docs reference wait_for and monitor but don't show what they do, test these functions and implement late
-- not a priority right now, but should be done
-- function UBus:wait_for(ctx, object, ...)
-- function UBus:monitor(ctx)

--- --------------------------------------------------------------------------------
--- --------------------------------------------------------------------------------

function UBus:handle_capability(ctx, request)
    local command = request.command
    local args = request.args
    local ret_ch = request.return_channel

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

    fiber.spawn(function()
        local result, err = func(self, ctx, unpack(args))

        ret_ch:put({
            result = result,
            err = err
        })
    end)
end

function UBus:apply_capabilities(capability_info_q)
    self.info_q = capability_info_q
    local capabilities = {
        ubus = {
            control = hal_capabilities.new_ubus_capability(self.cap_control_q),
            id = "1"
        }
    }
    return capabilities, nil
end

function UBus:_main(ctx)
    while not ctx:err() do
        op.choice(
            self.cap_control_q:get_op():wrap(function(req)
                self:handle_capability(ctx, req)
            end),
            ctx:done_op()
        ):perform()
    end
end

function UBus:spawn(conn)
    service.spawn_fiber("UBus Driver", conn, self.ctx, function(fctx)
        self:_main(fctx)
    end)
end

return { new = UBus.new }
