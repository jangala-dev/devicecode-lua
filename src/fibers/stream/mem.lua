-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- A memory-backed stream IO implementation.

local stream = require 'fibers.stream'
local sc = require 'fibers.utils.syscall'

local ffi = sc.is_LuaJIT and require 'ffi' or require 'cffi'

local Mem = {}
Mem.__index = Mem

local INITIAL_SIZE = 4096

local function new_buffer(len) return ffi.new('uint8_t[?]', len) end

local function new_mem_io(buf, len, size, growable)
    if buf == nil then
        if size == nil then size = len or INITIAL_SIZE end
        buf = new_buffer(size)
    else
        if size == nil then size = len end
        assert(size ~= nil)
    end
    if len == nil then len = 0 end
    return setmetatable(
        { buf = buf, pos = 0, len = len, size = size, growable = growable },
        Mem)
end

function Mem:nonblock() end

function Mem:block() end

function Mem:read(buf, count)
    count = math.min(count, self.len - self.pos)
    ffi.copy(buf, self.buf + self.pos, count)
    self.pos = self.pos + count
    return count
end

function Mem:grow_buffer(count)
    assert(self.growable, "ran out of space while writing")
    if self.len == self.size then
        self.size = math.max(self.size * 2, 1024)
        local buf = new_buffer(self.size)
        ffi.copy(buf, self.buf, self.len)
        self.buf = buf
    end
    self.len = math.min(self.size, self.len + count)
    return self.len
end

function Mem:write(buf, count)
    if self.pos == self.len then self:grow_buffer(count) end
    count = math.min(count, self.len - self.pos)
    ffi.copy(self.buf + self.pos, buf, count)
    self.pos = self.pos + count
    return count
end

function Mem:seek(whence, offset)
    if whence == sc.SEEK_CUR then
        offset = self.pos + offset
    elseif whence == sc.SEEK_END then
        offset = self.len + offset
    elseif whence ~= sc.SEEK_SET then
        error('bad "whence": ' .. tostring(whence))
    end
    if offset < 0 then return nil, "invalid offset" end
    while self.len < offset do self:grow_buffer(offset - self.len) end
    self.pos = offset
    return offset
end

function Mem:wait_for_readable() end

function Mem:wait_for_writable() end

function Mem:close()
    self.buf, self.pos, self.len, self.size, self.growable = nil, nil, nil, nil, nil
end

local readable_modes = { r = true, ['r+'] = true, ['w+'] = true }
local writable_modes = { ['r+'] = true, w = true, ['w+'] = true }

local function open(buf, len, mode)
    if mode == nil then mode = 'r+' end
    local readable, writable = readable_modes[mode], writable_modes[mode]
    assert(readable or writable)
    local io = new_mem_io(buf, len, len, writable)
    return stream.open(io, readable, writable)
end

local function tmpfile()
    return open()
end

local function open_input_string(str)
    local len = #str
    local buf = new_buffer(len)
    ffi.copy(buf, str, len)
    local readable, writable = true, false
    local io = new_mem_io(buf, len, len, writable)
    return stream.open(io, readable, writable)
end

local function call_with_output_string(f, ...)
    local out = tmpfile()
    local args = { ... }
    table.insert(args, out)
    f(unpack(args))
    out:flush_output()
    -- Can take advantage of internals to read directly.
    return ffi.string(out.io.buf, out.io.len)
end

return {
    open = open,
    tmpfile = tmpfile,
    open_input_string = open_input_string,
    call_with_output_string = call_with_output_string
}
