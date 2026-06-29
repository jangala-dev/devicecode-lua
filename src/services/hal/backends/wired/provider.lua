-- services/hal/backends/wired/provider.lua
-- Thin provider loader for semantic wired-provider backends.

local M = {}

local function provider_name(config)
	if type(config) ~= 'table' then return nil, 'wired provider config must be a table' end
	if type(config.provider) ~= 'string' or config.provider == '' then return nil, 'wired provider config requires provider' end
	return config.provider, nil
end

function M.new(config, opts)
	config = config or {}
	local name, name_err = provider_name(config)
	if not name then return nil, name_err end
	local modname = 'services.hal.backends.wired.providers.' .. name
	local ok, mod = pcall(require, modname)
	if not ok then return nil, ('wired provider %s not available: %s'):format(name, tostring(mod)) end
	if type(mod) ~= 'table' or type(mod.new) ~= 'function' then return nil, 'wired provider module must export new(config, opts)' end
	local backend, err = mod.new(config, opts or {})
	if not backend then return nil, err end
	return backend, nil, name
end

return M
