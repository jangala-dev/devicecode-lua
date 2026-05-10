-- services/device/config.lua
--
-- Raw Device configuration validation and normalisation.

local catalogue = require 'services.device.catalogue'

local M = {}

M.SCHEMA = 'devicecode.config/device/1'

local function unwrap_config(raw)
	if raw == nil then return nil end
	if type(raw) ~= 'table' then
		return nil, 'device config must be a table'
	end
	if raw.data ~= nil and type(raw.data) == 'table' then
		return raw.data, nil
	end
	return raw, nil
end

function M.normalise(raw)
	local cfg, err = unwrap_config(raw)
	if err then return nil, err end
	if cfg ~= nil and cfg.schema ~= nil and cfg.schema ~= M.SCHEMA then
		return nil, 'unsupported device config schema: ' .. tostring(cfg.schema)
	end
	return cfg, nil
end

M.normalize = M.normalise

function M.to_catalogue(raw)
	local cfg, err = M.normalise(raw)
	if err then return nil, err end

	local ok, cat_or_err = pcall(function ()
		return catalogue.build(cfg)
	end)
	if not ok then
		return nil, tostring(cat_or_err)
	end
	return cat_or_err, nil
end

function M.catalogues_equal(a, b)
	return catalogue.materially_equal(a, b)
end

return M
