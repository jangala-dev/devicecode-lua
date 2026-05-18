-- services/wired/projection.lua
-- Public state projection for Wired.

local tablex = require 'shared.table'
local topics = require 'services.wired.topics'

local M = {}

local function copy(v) return tablex.deep_copy(v) end
local function count_map(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

function M.summary_topic() return topics.summary() end
function M.surface_topic(id) return topics.surface(id) end
function M.provider_topic(id) return topics.provider(id) end
function M.topology_topic() return topics.topology() end
function M.violations_topic() return topics.violations() end

function M.summary(snapshot)
	snapshot = snapshot or {}
	return {
		service = 'wired',
		state = snapshot.state,
		ready = snapshot.ready == true,
		reason = snapshot.reason,
		generation = snapshot.generation,
		config = copy(snapshot.config),
		counts = {
			surfaces = count_map(snapshot.surfaces),
			providers = count_map(snapshot.providers),
			violations = #(snapshot.violations or {}),
		},
		stats = copy(snapshot.stats),
	}
end

function M.surface(rec) return copy(rec or {}) end
function M.provider(rec) return copy(rec or {}) end
function M.topology(snapshot) return copy((snapshot or {}).topology or {}) end
function M.violations(snapshot) return copy((snapshot or {}).violations or {}) end

return M
