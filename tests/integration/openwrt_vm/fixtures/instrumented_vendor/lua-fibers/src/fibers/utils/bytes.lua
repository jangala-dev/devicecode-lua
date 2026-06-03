-- fibers/utils/bytes.lua
--
-- Unified buffer abstraction:
--   * bytes.RingBuf   : ring buffer for bytes
--   * bytes.LinearBuf : growable linear buffer
--
-- Backend selection:
--   - FFI-backed (LuaJIT or cffi)   : fibers.utils.bytes.ffi
--   - Pure Lua rope/string-based    : fibers.utils.bytes.lua
--
-- This shim picks the first supported backend.

---@module 'fibers.utils.bytes'

----------------------------------------------------------------------
-- Forward type declarations for tooling
----------------------------------------------------------------------

---@class RingBuf
---@field size integer                                   # total capacity (bytes)
---@field read_avail fun(self: RingBuf): integer         # available bytes to read
---@field write_avail fun(self: RingBuf): integer        # available space to write
---@field take fun(self: RingBuf, n: integer): string    # remove n bytes and return them
---@field put fun(self: RingBuf, s: string)              # append bytes
---@field reset fun(self: RingBuf)                       # clear buffer
---@field find fun(self: RingBuf, needle: string): integer|nil  # find substring in readable region

---@class LinearBuf
---@field append fun(self: LinearBuf, s: string)         # append bytes
---@field tostring fun(self: LinearBuf): string          # materialise as a single string
---@field reset fun(self: LinearBuf)                     # clear buffer (optional but common)

---@class BytesBackend
---@field RingBuf   { new: fun(size?: integer): RingBuf }
---@field LinearBuf { new: fun(): LinearBuf }
---@field is_supported fun(): boolean

local candidates = {
	'fibers.utils.bytes.ffi',
	'fibers.utils.bytes.lua',
}

for _, name in ipairs(candidates) do
	local ok, mod = pcall(require, name)
	if ok and type(mod) == 'table' and mod.is_supported and mod.is_supported() then
		return mod
	end
end

error('fibers.utils.bytes: no suitable bytes backend available on this platform')
