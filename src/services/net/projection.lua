-- services/net/projection.lua
-- Public state projection for NET.

local tablex = require 'shared.table'
local topics = require 'services.net.topics'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

local function count_map(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

function M.summary_topic() return topics.summary() end
function M.apply_topic() return topics.apply() end
function M.segment_topic(id) return topics.segment(id) end
function M.segments_topic() return topics.segments() end
function M.vlan_policy_topic() return topics.vlan_policy() end
function M.interface_topic(id) return topics.interface(id) end
function M.domain_topic(name) return topics.domain(name) end

function M.summary(snapshot)
	snapshot = snapshot or {}
	return {
		service = 'net',
		state = snapshot.state,
		ready = snapshot.ready == true,
		reason = snapshot.reason,
		generation = snapshot.generation,
		config = copy(snapshot.config),
		apply = copy(snapshot.apply),
		hal = copy(snapshot.hal),
		counts = {
			segments = count_map(snapshot.segments),
			interfaces = count_map(snapshot.interfaces),
			wan_members = count_map(snapshot.wan and snapshot.wan.members),
			vpn_tunnels = count_map(snapshot.vpn and snapshot.vpn.tunnels),
			shaping_profiles = count_map(snapshot.shaping and snapshot.shaping.profiles),
		},
		drift = copy(snapshot.drift),
		observed = {
			last_event_at = snapshot.observed and snapshot.observed.last_event_at or nil,
			last_subject = snapshot.observed and snapshot.observed.last_subject or nil,
		},
		stats = copy(snapshot.stats),
	}
end

function M.apply(snapshot) return copy((snapshot or {}).apply or {}) end
function M.segments(snapshot)
	snapshot = snapshot or {}
	return {
		service = 'net',
		kind = 'net.segments',
		generation = snapshot.generation,
		rev = snapshot.config and snapshot.config.rev or nil,
		segments = copy(snapshot.segments or {}),
		vlan_policy = copy(snapshot.vlan_policy or ((snapshot.policies or {}).vlan) or {}),
	}
end
function M.vlan_policy(snapshot) return copy((snapshot or {}).vlan_policy or (((snapshot or {}).policies or {}).vlan) or {}) end
function M.segment(seg) return copy(seg or {}) end
function M.interface(iface) return copy(iface or {}) end
function M.domain(snapshot, name) return copy((snapshot or {})[name] or {}) end

return M
