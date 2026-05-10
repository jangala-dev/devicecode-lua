-- services/update/model.lua
--
-- Update service snapshot helpers and observable model factory.

local base_model = require 'devicecode.support.model'
local tablex     = require 'shared.table'

local M = {}
local BaseModel = base_model.Model
local Model = {}

Model.__index = function (_, key)
	return Model[key] or BaseModel[key]
end

local is_array   = tablex.is_array
local deep_copy  = tablex.deep_copy
local deep_equal = tablex.deep_equal

function M.service_initial(service_id, generation)
	return {
		service    = service_id or 'update',
		state      = 'starting',
		ready      = false,
		generation = generation or 0,
		reason     = nil,
		config     = nil,
		active     = nil,
		update_active = nil,
		jobs       = { count = 0, by_id = {} },
		ingest     = { count = 0, by_id = {} },
		publisher  = { state = 'starting' },
	}
end

function M.generation_initial(params)
	params = params or {}
	return {
		service    = params.service_id or 'update',
		generation = params.generation or 1,
		state      = 'starting',
		ready      = false,
		config     = deep_copy(params.config or {}),
		jobs       = { count = 0, by_id = {} },
		ingest     = { count = 0, by_id = {} },
		components = deep_copy(params.components or {}),
		bundled    = deep_copy(params.bundled or {}),
	}
end

function Model:terminate(reason)
	return BaseModel.terminate(self, reason)
end

function M.new(initial, opts)
	opts = opts or {}
	local instance = base_model.new(initial or {}, {
		copy = opts.copy or deep_copy,
		equals = opts.equals or deep_equal,
		label = opts.label or 'update.model',
	})
	return setmetatable(instance, Model)
end

M.deep_copy = deep_copy
M.deep_equal = deep_equal
M.is_array = is_array
M.Model = Model

return M
