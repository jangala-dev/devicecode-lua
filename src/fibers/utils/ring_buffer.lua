-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- Ring buffer for bytes

-- detect LuaJIT (removing dependency on utils.syscall)
local is_LuaJIT = rawget(_G, "jit") and true or false

local bit = rawget(_G, "bit") or require 'bit32'
local ffi = is_LuaJIT and require 'ffi' or require 'cffi'

local band = bit.band

ffi.cdef [[
   typedef struct {
      uint32_t read_idx, write_idx;
      uint32_t size;
      uint8_t buf[?];
   } buffer_t;
]]

local function to_uint32(n)
    return n % 2 ^ 32
end

local buffer = {}
buffer.__index = buffer

function buffer:init(size)
    assert(size ~= 0 and band(size, size - 1) == 0, "size not power of two")
    self.size = size
    return self
end

function buffer:reset()
    self.write_idx, self.read_idx = 0, 0
end

function buffer:is_empty()
    return self.write_idx == self.read_idx
end

function buffer:read_avail()
    return to_uint32(self.write_idx - self.read_idx)
end

function buffer:is_full()
    return self:read_avail() == self.size
end

function buffer:write_avail()
    return self.size - self:read_avail()
end

function buffer:write_pos()
    return band(self.write_idx, self.size - 1)
end

function buffer:rewrite_pos(offset)
    return band(self.read_idx + offset, self.size - 1)
end

function buffer:read_pos()
    return band(self.read_idx, self.size - 1)
end

function buffer:advance_write(count)
    self.write_idx = self.write_idx + ffi.cast("uint32_t", count)
end

function buffer:advance_read(count)
    self.read_idx = self.read_idx + ffi.cast("uint32_t", count)
end

function buffer:write(bytes, count)
    if count > self:write_avail() then error('write xrun') end
    local pos = self:write_pos()
    local count1 = math.min(self.size - pos, count)
    ffi.copy(self.buf + pos, bytes, count1)
    ffi.copy(self.buf, bytes + count1, count - count1)
    self:advance_write(count)
end

function buffer:rewrite(offset, bytes, count)
    if offset + count > self:read_avail() then error('rewrite xrun') end
    local pos = self:rewrite_pos(offset)
    local count1 = math.min(self.size - pos, count)
    ffi.copy(self.buf + pos, bytes, count1)
    ffi.copy(self.buf, bytes + count1, count - count1)
end

function buffer:read(bytes, count)
    if count > self:read_avail() then error('read xrun') end
    local pos = self:read_pos()
    local count1 = math.min(self.size - pos, count)
    ffi.copy(bytes, self.buf + pos, count1)
    ffi.copy(bytes + count1, self.buf, count - count1)
    self:advance_read(count)
end

function buffer:drop(count)
    if count > self:read_avail() then error('read xrun') end
    self:advance_read(count)
end

function buffer:peek()
    local pos = self:read_pos()
    return self.buf + pos, math.min(self:read_avail(), self.size - pos)
end

local buffer_t = ffi.metatype("buffer_t", buffer)

local function new(size)
    local ret = buffer_t(size)
    ret:init(size)
    return ret
end

return {
    new = new
}
