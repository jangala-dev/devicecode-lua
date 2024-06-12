-- Use of the provided source code for ring buffer

local ring_buffer = require 'fibers.utils.ring_buffer' -- assuming the above code is saved as ring_buffer.lua

local is_LuaJIT = rawget(_G, "jit") and true or false
local ffi = is_LuaJIT and require 'ffi' or require 'cffi'

local str_buffer = {}
str_buffer.__index = str_buffer

function str_buffer.new(size)
    local obj = {}
    obj.buf = ring_buffer.new(size or 64) -- Default size is 64
    return setmetatable(obj, str_buffer)
end

function str_buffer:len()
    return self.buf:read_avail()
end

function str_buffer:cap()
    return self.buf.size
end

function str_buffer:reset()
    self.buf:reset()
end

function str_buffer:string()
    local data, length = self.buf:peek()
    return ffi.string(data, length)
end

function str_buffer:write(data)
    if not data then return end
    local len = #data

    if self.buf:write_avail() < len then
        self:grow(len - self.buf:write_avail())
    end

    local cdata = ffi.new("uint8_t[?]", len)
    ffi.copy(cdata, data, len)
    self.buf:write(cdata, len)
end

function str_buffer:write_to(w)
    -- Assuming 'w' is a function or a file-like object that can accept a string.
    local data = self:string()
    w(data)
    self.buf:drop(#data)
end

function str_buffer:read(n)
    local count = n or self.buf:read_avail()
    local buffer = ffi.new('uint8_t[?]', count)
    self.buf:read(buffer, count)
    return ffi.string(buffer, count)
end

function str_buffer:next(n)
    local buffer = ffi.new('uint8_t[?]', n)
    self.buf:read(buffer, n)
    return ffi.string(buffer, n)
end

function str_buffer:unread_char()
    -- for simplicity, we'll just advance the read index backward by 1
    self.buf:advance_read(-1)
end

function str_buffer:grow(n)
    if n < 0 then
        error("str_buffer: negative count")
    end

    local new_size = self:cap() + n
    -- Round up to the nearest power of 2 for efficiency.
    local power = 1
    while power < new_size do
        power = power * 2
    end
    new_size = power

    local new_buf = ring_buffer.new(new_size)

    -- Handle wrap around
    local first_chunk_len = math.min(self.buf:read_avail(), self.buf.size - self.buf:read_pos())
    local second_chunk_len = self.buf:read_avail() - first_chunk_len

    -- Copy from old buffer to the new buffer in two steps if wrapped around
    new_buf:write(self.buf.buf + self.buf:read_pos(), first_chunk_len)
    if second_chunk_len > 0 then
        new_buf:write(self.buf.buf, second_chunk_len)
    end

    self.buf = new_buf
end

return {
    new = str_buffer.new
}
