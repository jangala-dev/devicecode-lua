-- services/hal/backends/wired/provider.lua
-- Thin provider loader for semantic wired-provider backends.

local M = {}

local function provider_name(config)
	return tostring((config and (config.provider or config.backend or config.kind)) or 'static')
end

function M.new(config, opts)
	config = config or {}
	local name = provider_name(config)
	local modname = 'services.hal.backends.wired.providers.' .. name
	local ok, mod = pcall(require, modname)
	if not ok then return nil, ('wired provider %s not available: %s'):format(name, tostring(mod)) end
	if type(mod) ~= 'table' or type(mod.new) ~= 'function' then return nil, 'wired provider module must export new(config, opts)' end
	return mod.new(config, opts or {})
end

return M
