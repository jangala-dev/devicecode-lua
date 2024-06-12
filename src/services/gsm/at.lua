package.path = "../src/?.lua;../?.lua;" .. package.path

-- Importing the necessary modules
local fiber = require 'fibers.fiber'
local context = require 'fibers.context'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local pollio = require 'fibers.pollio'
local file = require 'fibers.stream.file'

pollio.install_poll_io_handler()

local function at_context(ctx, port, command)
    local read_stream = assert(file.open(port, 'r'))
    local write_stream = assert(file.open(port, 'w')):setvbuf('no')

    local function close_streams() write_stream:close(); read_stream:close() end

    -- first, send command to AT port
    op.choice(
        pollio.stream_writable_op(write_stream):wrap(function ()
            -- print("sending command!")
            write_stream:write(command .. '\r\n')
        end),
        ctx:done_op()
    ):perform()

    if ctx:err() then close_streams() return nil, "couldn't send at command" end

    -- next, read the response
    local res = {}
    local complete = false
    while not complete do
        -- print("looping around at output")
        op.choice(
            pollio.stream_readable_op(read_stream):wrap(function ()
                local chars = read_stream:read_some_chars()
                -- print("output:", chars)
                table.insert(res, chars)
                -- if not chars or chars:find("ERROR") or chars:match("OK\r\n$") then
                if not chars or chars:match("ERROR.*\r\n$") or chars:match("OK\r\n$") then
                    complete = true
                end
            end),
            ctx:done_op():wrap(function () complete = true end)
        ):perform()
    end

    close_streams()
    
    return ctx:err() and nil or table.concat(res), ctx:err()
end

return {
    at_context = at_context
}