-- fibers/utils/ffi_compat.lua
--
-- Unified wrapper around LuaJIT ffi and cffi.
--
-- Exposes:
--   M.ffi      : the provider module (luajit ffi or cffi)
--   M.C        : ffi.C
--   M.tonumber : cdata-aware tonumber
--   M.type     : cdata-aware type
--   M.errno    : errno getter
--   M.is_null  : NULL / nullptr check for pointers

local ok, ffi = pcall(require, 'ffi')
local provider = 'luajit_ffi'

if not ok then
	local ok2, cffi = pcall(require, 'cffi')
	if not ok2 then
		return {
			is_supported = function () return false end,
		}
	end
	ffi = cffi
	provider = 'cffi'
end

-- Normalise helper functions.
local tonumber_fn = rawget(ffi, 'tonumber') or tonumber
local type_fn     = rawget(ffi, 'type') or type

local function errno()
	-- Both LuaJIT ffi and cffi expose errno() in their API.
	return ffi.errno()
end

local function is_null(ptr)
	-- For LuaJIT ffi, NULL pointers compare equal to nil.
	-- For cffi, you must compare with cffi.nullptr.
	if ptr == nil then
		return true
	end
	local ffi_nullptr = rawget(ffi, 'nullptr')
	if ffi_nullptr and ptr == ffi_nullptr then
		return true
	end
	return false
end

local M = {
	ffi          = ffi,
	C            = ffi.C,
	provider     = provider,
	tonumber     = tonumber_fn,
	type         = type_fn,
	errno        = errno,
	is_null      = is_null,
	is_supported = function () return true end,
}

return M
