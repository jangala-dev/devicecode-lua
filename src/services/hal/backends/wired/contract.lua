-- services/hal/backends/wired/contract.lua
-- Semantic wired-provider backend contract.
--
-- Providers expose product-level wired surfaces.  They do not expose switch ASIC
-- registers, HTTP endpoints, DSA syntax or OpenWrt implementation details.
--
-- Phase 1 providers are observation-only and must return read_only for control.

local M = {}

M.CAP_CLASS = 'wired-provider'
M.SCHEMA = 'devicecode.hal.wired-provider/1'

function M.read_only(method)
	return {
		ok = false,
		code = 'read_only',
		err = tostring(method or 'operation') .. ' is not available on this read-only wired provider',
	}
end

return M
