-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- Shim to replace Lua's built-in IO module with streams.

local stream = require 'fibers.stream'
local file = require 'fibers.stream.file'
local sc = require 'fibers.utils.syscall'

local original_io = _G.io -- Save the original io module
local io = {}

function io.close(f)
    if f == nil then f = io.current_output end
    f:close()
end

function io.flush()
    io.current_output:flush()
end

function io.input(new)
    if new == nil then return io.current_input end
    if type(new) == string then new = io.open(new, 'r') end
    io.current_input = new
end

function io.lines(filename, ...)
    if filename == nil then return io.current_input:lines() end
    local fileStream = assert(io.open(filename, 'r'))
    local iter = fileStream:lines(...)
    return function()
        local line = { iter() }
        if line[1] == nil then
            fileStream:close()
            return nil
        end
        return unpack(line)
    end
end

io.open = file.open

function io.output(new)
    if new == nil then return io.current_output end
    if type(new) == string then new = io.open(new, 'w') end
    io.current_output = new
end

function io.popen(prog, mode)
    return file.popen(prog, mode)
end

function io.read(...)
    return io.current_input:read(...)
end

io.tmpfile = file.tmpfile

function io.type(x)
    if not stream.is_stream(x) then return nil end
    if not x.io then return 'closed file' end
    return 'file'
end

function io.write(...)
    return io.current_output:write(...)
end

local function install()
    if _G.io == io then return end
    _G.io = io
    io.stdin = file.fdopen(sc.STDIN_FILENO, sc.O_RDONLY)
    io.stdout = file.fdopen(sc.STDOUT_FILENO, sc.O_WRONLY)
    io.stderr = file.fdopen(sc.STDERR_FILENO, sc.O_WRONLY)
    if sc.isatty(io.stdout.io.fd) then io.stdout:setvbuf('line') end
    io.stderr:setvbuf('no')
    io.input(io.stdin)
    io.output(io.stdout)
end

local function uninstall()
   _G.io = original_io
end

return {
   install = install,
   uninstall = uninstall
}
