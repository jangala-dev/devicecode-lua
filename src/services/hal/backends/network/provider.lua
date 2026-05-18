-- services/hal/backends/network/provider.lua
-- Network backend provider loader.

local contract = require 'services.hal.backends.network.contract'

local M = {}

function M.new(config, opts)
	config = config or {}
	opts = opts or {}
	local name = config.provider or config.backend or opts.provider or 'fake'
	local modname = 'services.hal.backends.network.providers.' .. tostring(name) .. '.init'
	local ok, mod_or_err = pcall(require, modname)
	if not ok then return nil, mod_or_err end
	local provider, err = mod_or_err.new(config, opts)
	if not provider then return nil, err end
	local valid, verr = contract.validate_provider(provider)
	if valid ~= true then return nil, verr end
	return provider, nil
end

return M
