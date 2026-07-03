-- services/wired/model.lua
-- Observable Wired service model.

local support_model = require 'devicecode.support.model'
local tablex = require 'shared.table'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

function M.initial(service_id)
	return {
		service = 'wired',
		service_id = service_id,
		state = 'starting',
		ready = false,
		reason = nil,
		generation = 0,
		config = { rev = nil, schema = nil, config_schema = nil, version = nil },
		net = { segments_rev = nil, segments = {}, vlan_policy = {}, missing_segments = {} },
		observations = {},
		assembly = {},
		dependencies = {},
		surfaces = {},
		counters = {},
		topology = { protected_trunks = {}, access = {}, trunks = {} },
		violations = {},
		stats = { config_updates = 0, segment_updates = 0, observation_updates = 0, assembly_updates = 0, publications = 0 },
	}
end

function M.new(service_id, opts)
	opts = opts or {}
	return support_model.new(M.initial(service_id), { label = opts.label or 'wired.model', copy = copy })
end

function M.deep_copy(v) return copy(v) end

return M
