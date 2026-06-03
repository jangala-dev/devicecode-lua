-- fibers/utils/bytes/lua.lua
--
-- Pure Lua byte buffers:
--   * RingBuf   : fixed-capacity ring buffer (rope of strings)
--   * LinearBuf : growable buffer (rope of strings)

---@module 'fibers.utils.bytes.lua'

----------------------------------------------------------------------
-- Shared rope helpers
----------------------------------------------------------------------

local function rope_tostring(chunks, head_idx, head_off)
	local n = #chunks
	if head_idx > n then
		return ''
	end

	local out = {}
	local first = chunks[head_idx]
	if head_off > 0 then
		first = first:sub(head_off + 1)
	end
	out[1] = first

	for i = head_idx + 1, n do
		out[#out + 1] = chunks[i]
	end

	return table.concat(out)
end

----------------------------------------------------------------------
-- RingBuf
----------------------------------------------------------------------

---@class LuaRingBuf : RingBuf
local RingBuf_mt = {}
RingBuf_mt.__index = RingBuf_mt

local function RingBuf_new(size)
	assert(type(size) == 'number' and size > 0,
		'RingBuf.new: positive size required')
	return setmetatable({
		chunks   = {},
		head_idx = 1,
		head_off = 0,
		len      = 0,
		size     = size,
	}, RingBuf_mt)
end

local function compact(self)
	local hi = self.head_idx
	if hi <= 8 and hi <= (#self.chunks / 2) then
		return
	end
	for i = 1, hi - 1 do
		self.chunks[i] = nil
	end
	local k = 1
	for j = hi, #self.chunks do
		self.chunks[k] = self.chunks[j]
		if k ~= j then
			self.chunks[j] = nil
		end
		k = k + 1
	end
	self.head_idx = 1
end

function RingBuf_mt:reset()
	self.chunks   = {}
	self.head_idx = 1
	self.head_off = 0
	self.len      = 0
end

function RingBuf_mt:read_avail()
	return self.len
end

function RingBuf_mt:write_avail()
	return self.size - self.len
end

function RingBuf_mt:is_empty()
	return self.len == 0
end

function RingBuf_mt:is_full()
	return self.len >= self.size
end

function RingBuf_mt:advance_read(n)
	assert(n >= 0 and n <= self.len, 'RingBuf:advance_read out of range')
	if n == 0 then return end

	self.len = self.len - n

	local i   = self.head_idx
	local off = self.head_off

	while n > 0 and i <= #self.chunks do
		local chunk = self.chunks[i]
		local rem   = #chunk - off
		if n < rem then
			off = off + n
			n   = 0
		else
			n   = n - rem
			i   = i + 1
			off = 0
		end
	end

	self.head_idx = i
	self.head_off = off
	compact(self)
end

function RingBuf_mt:write(src, count)
	assert(type(src) == 'string', 'RingBuf:write expects string')
	local n = count or #src
	assert(n <= #src, 'RingBuf:write count > #src')
	assert(n <= self:write_avail(), 'RingBuf: write xrun')
	if n == 0 then return end

	local s = src
	if n < #s then
		s = s:sub(1, n)
	end
	self.len = self.len + n
	self.chunks[#self.chunks + 1] = s
end

function RingBuf_mt:read(_, count)
	assert(count >= 0 and count <= self.len, 'RingBuf: read xrun')
	if count == 0 then
		return ''
	end

	local out  = {}
	local need = count
	local i    = self.head_idx
	local off  = self.head_off
	local n    = #self.chunks

	while need > 0 and i <= n do
		local chunk   = self.chunks[i]
		local rem     = #chunk - off
		local take    = math.min(need, rem)
		out[#out + 1] = chunk:sub(off + 1, off + take)
		need          = need - take
		if take == rem then
			i   = i + 1
			off = 0
		else
			off = off + take
		end
	end

	local s       = table.concat(out)
	self.head_idx = i
	self.head_off = off
	self.len      = self.len - count
	compact(self)
	return s
end

function RingBuf_mt:put(str)
	assert(type(str) == 'string', 'RingBuf:put expects a string')
	local n = #str
	if n == 0 then return end
	assert(n <= self:write_avail(), 'RingBuf: write would exceed capacity')
	self:write(str, n)
end

-- Opaque mark of the current write position (for tail rollback).
-- We only need enough state to drop newly appended chunks and restore len.
function RingBuf_mt:mark_write()
	return { n = #self.chunks, len = self.len }
end

-- Rewind the write position to a previously obtained mark.
-- Caller must ensure no consumer progress happened since the mark.
function RingBuf_mt:rewind_write(mark)
	assert(type(mark) == 'table', 'RingBuf:rewind_write expects mark table')
	local n = mark.n or 0
	local len = mark.len or 0

	for i = #self.chunks, n + 1, -1 do
		self.chunks[i] = nil
	end

	self.len = len
end

function RingBuf_mt:take(n)
	assert(type(n) == 'number' and n >= 0, 'RingBuf:take expects non-negative count')
	if self.len == 0 or n == 0 then
		return ''
	end
	if n > self.len then
		n = self.len
	end
	return self:read(nil, n)
end

function RingBuf_mt:tostring()
	if self.len == 0 then
		return ''
	end
	return rope_tostring(self.chunks, self.head_idx, self.head_off)
end

function RingBuf_mt:find(pattern)
	assert(type(pattern) == 'string' and #pattern > 0,
		'RingBuf:find expects non-empty string')
	local s = self:tostring()
	local i = s:find(pattern, 1, true)
	return i and (i - 1) or nil
end

function RingBuf_mt:capacity()
	return self.size
end

function RingBuf_mt:peek(n)
	assert(type(n) == 'number' and n >= 0, 'RingBuf:peek expects non-negative count')
	if n == 0 or self.len == 0 then
		return ''
	end
	if n > self.len then
		n = self.len
	end

	-- Same as read(nil, n) but without advancing.
	local out  = {}
	local need = n
	local i    = self.head_idx
	local off  = self.head_off
	local last = #self.chunks

	while need > 0 and i <= last do
		local chunk = self.chunks[i]
		local rem   = #chunk - off
		local take  = math.min(need, rem)
		out[#out + 1] = chunk:sub(off + 1, off + take)
		need = need - take
		if take == rem then
			i = i + 1
			off = 0
		else
			off = off + take
		end
	end

	return table.concat(out)
end

----------------------------------------------------------------------
-- LinearBuf
----------------------------------------------------------------------

---@class LuaLinearBuf : LinearBuf
local LinearBuf_mt = {}
LinearBuf_mt.__index = LinearBuf_mt

local function LinearBuf_new(_)
	return setmetatable({
		chunks   = {},
		head_idx = 1,
		head_off = 0,
		len      = 0,
	}, LinearBuf_mt)
end

function LinearBuf_mt:reset()
	self.chunks   = {}
	self.head_idx = 1
	self.head_off = 0
	self.len      = 0
end

function LinearBuf_mt:append(s)
	if not s or #s == 0 then return end
	self.len = self.len + #s
	self.chunks[#self.chunks + 1] = s
end

function LinearBuf_mt:tostring()
	if self.len == 0 then
		return ''
	end
	return rope_tostring(self.chunks, self.head_idx, self.head_off)
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	RingBuf      = { new = RingBuf_new },
	LinearBuf    = { new = LinearBuf_new },
	has_ffi      = false,
	is_supported = function () return true end,
}
