-- services/update/config.lua
--
-- Pure update configuration validation and normalisation.

local model = require 'services.update.model'
local tablex = require 'shared.table'

local M = {}

M.SCHEMA = 'devicecode.update/1'

local function copy(v)
	return tablex.deep_copy(v)
end

local function table_or_empty(v)
	if v == nil then return {} end
	if type(v) ~= 'table' then return nil, 'expected table' end
	return tablex.deep_copy(v), nil
end

local function sorted_count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function normalise_components(raw)
	local out = {}
	local list = raw or {}

	if model.is_array(list) then
		for i = 1, #list do
			local item = list[i]
			if type(item) ~= 'table' then
				return nil, 'components entries must be tables'
			end
			local id = item.id or item.name or item.component
			if type(id) ~= 'string' or id == '' then
				return nil, 'component id/name must be a non-empty string'
			end
			if out[id] ~= nil then
				return nil, 'duplicate component: ' .. id
			end
			local c = copy(item)
			c.id = id
			out[id] = c
		end
	else
		for id, item in pairs(list) do
			if type(id) ~= 'string' or id == '' then
				return nil, 'component map keys must be non-empty strings'
			end
			if type(item) ~= 'table' then
				return nil, 'component entries must be tables'
			end
			local c = copy(item)
			c.id = c.id or id
			out[id] = c
		end
	end

	return out, nil
end

local function summarise(cfg)
	return {
		rev             = cfg.rev,
		schema          = cfg.schema,
		service_id      = cfg.service_id,
		namespace       = cfg.namespace,
		component_count = sorted_count(cfg.components),
		bundled_enabled = cfg.bundled and cfg.bundled.enabled == true or false,
	}
end

--- Extract the data table from a config-service retained payload.
function M.extract_payload(v)
	local payload = v
	if type(payload) == 'table' and payload.payload ~= nil then
		payload = payload.payload
	end
	if type(payload) == 'table' and payload.data ~= nil then
		return payload.data, payload.rev
	end
	return payload, nil
end

function M.normalise(raw, opts)
	opts = opts or {}
	raw = raw or {}
	if type(raw) ~= 'table' then
		return nil, 'update config must be a table'
	end

	local components, cerr = normalise_components(raw.components)
	if not components then
		return nil, cerr
	end

	local bundled, berr = table_or_empty(raw.bundled)
	if not bundled then return nil, 'bundled: ' .. tostring(berr) end

	local publish, perr = table_or_empty(raw.publish)
	if not publish then return nil, 'publish: ' .. tostring(perr) end
	if publish.enabled == nil then publish.enabled = true end

	local out = {
		schema     = raw.schema or M.SCHEMA,
		rev        = opts.rev or raw.rev,
		service_id = raw.service_id or opts.service_id or 'update',
		namespace  = raw.namespace or raw.ns or 'default',
		components = components,
		bundled    = bundled,
		publish    = publish,
		raw        = copy(raw),
	}

	if out.schema ~= M.SCHEMA then
		return nil, 'unsupported update config schema: ' .. tostring(out.schema)
	end

	out.summary = summarise(out)
	return out, nil
end

function M.default(opts)
	return assert(M.normalise({}, opts))
end

function M.material_equal(a, b)
	return model.deep_equal(a and a.raw or a, b and b.raw or b)
end

function M.summary(cfg)
	return cfg and copy(cfg.summary or summarise(cfg)) or nil
end

return M
