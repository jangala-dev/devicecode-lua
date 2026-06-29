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

local function normalise_optional_positive_number(t, key, where)
	local v = t[key]
	if v == nil then return true, nil end
	local n = tonumber(v)
	if type(n) ~= 'number' or n <= 0 then
		return false, where .. '.' .. key .. ' must be a positive number'
	end
	t[key] = n
	return true, nil
end


local function normalise_non_negative_integer(t, key, where)
	local v = t[key]
	if v == nil then return true, nil end
	local n = tonumber(v)
	if type(n) ~= 'number' or n < 0 or n ~= math.floor(n) then
		return false, where .. '.' .. key .. ' must be a non-negative integer'
	end
	t[key] = n
	return true, nil
end

local function normalise_optional_positive_integer(t, key, where)
	local v = t[key]
	if v == nil then return true, nil end
	local n = tonumber(v)
	if type(n) ~= 'number' or n <= 0 or n ~= math.floor(n) then
		return false, where .. '.' .. key .. ' must be a positive integer'
	end
	t[key] = n
	return true, nil
end

local function normalise_retention(raw)
	local retention, rerr = table_or_empty(raw)
	if not retention then return nil, rerr end
	if retention.prune_on_startup == nil then retention.prune_on_startup = false end
	if retention.prune_on_startup ~= true and retention.prune_on_startup ~= false then
		return nil, 'retention.prune_on_startup must be boolean'
	end
	local ok, err = normalise_non_negative_integer(retention, 'terminal_max_count', 'retention')
	if not ok then return nil, err end
	ok, err = normalise_optional_positive_integer(retention, 'terminal_max_age_s', 'retention')
	if not ok then return nil, err end
	ok, err = normalise_non_negative_integer(retention, 'active_intent_restart_max', 'retention')
	if not ok then return nil, err end
	if retention.active_intent_restart_max == nil then retention.active_intent_restart_max = 1 end
	return retention, nil
end

local function normalise_component_timeouts(c, where)
	for _, key in ipairs({ 'timeout_s', 'stage_timeout_s', 'commit_timeout_s', 'reconcile_timeout_s' }) do
		local ok, err = normalise_optional_positive_number(c, key, where)
		if not ok then return nil, err end
	end
	return c, nil
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
			local id = item.component
			if type(id) ~= 'string' or id == '' then
				return nil, 'component must be a non-empty string'
			end
			if item.id ~= nil or item.name ~= nil then
				return nil, 'component entries must use component, not id or name'
			end
			if out[id] ~= nil then
				return nil, 'duplicate component: ' .. id
			end
			local c = copy(item)
			c.component = id
			local ok, terr = normalise_component_timeouts(c, 'components[' .. tostring(i) .. ']')
			if not ok then return nil, terr end
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
			if item.id ~= nil or item.name ~= nil then
				return nil, 'component entries must use component, not id or name'
			end
			if item.component ~= nil and item.component ~= id then
				return nil, 'component field must match component map key'
			end
			local c = copy(item)
			c.component = id
			local ok, terr = normalise_component_timeouts(c, 'components.' .. id)
			if not ok then return nil, terr end
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

	local retention, rerr = normalise_retention(raw.retention)
	if not retention then return nil, 'retention: ' .. tostring(rerr) end

	local out = {
		schema     = raw.schema or M.SCHEMA,
		rev        = opts.rev or raw.rev,
		service_id = raw.service_id or opts.service_id or 'update',
		namespace  = raw.namespace or 'default',
		components = components,
		bundled    = bundled,
		publish    = publish,
		retention  = retention,
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
