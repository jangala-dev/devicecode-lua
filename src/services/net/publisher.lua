-- services/net/publisher.lua
-- Immediate retained-state publication for NET, with explicit dirty state.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local projection = require 'services.net.projection'

local M = {}

local DOMAIN_TOPICS = {
	'addressing', 'dns', 'dhcp', 'firewall', 'routing',
	'wan', 'wan_runtime', 'sources', 'vpn', 'diagnostics', 'observed', 'drift',
}


local function publish_map(conn, published, next_map, dirty_map, topic_fn, payload_fn)
	local seen = {}
	next_map = next_map or {}
	for id, rec in pairs(next_map) do
		seen[id] = true
		if dirty_map == true or (type(dirty_map) == 'table' and dirty_map[id]) or not published[id] then
			local ok, err = bus_cleanup.retain(conn, topic_fn(id), payload_fn(rec))
			if ok ~= true then return nil, err end
			published[id] = true
		end
	end
	for id in pairs(published) do
		if not seen[id] then
			local ok, err = bus_cleanup.unretain(conn, topic_fn(id))
			if ok ~= true then return nil, err end
			published[id] = nil
		end
	end
	return true, nil
end

function M.new_state()
	return {
		segments = {},
		interfaces = {},
		domains = {},
		summary = false,
		apply = false,
		segments_catalogue = false,
		vlan_policy = false,
	}
end

function M.new_dirty_state()
	return {
		summary = false,
		apply = false,
		segments = {},
		interfaces = {},
		domains = {},
		segments_catalogue = false,
		vlan_policy = false,
	}
end

function M.mark_all(dirty)
	dirty.summary = true
	dirty.apply = true
	dirty.segments = true
	dirty.interfaces = true
	dirty.domains = true
	dirty.segments_catalogue = true
	dirty.vlan_policy = true
	return dirty
end

function M.mark_summary(dirty) dirty.summary = true; return dirty end
function M.mark_apply(dirty) dirty.apply = true; dirty.summary = true; return dirty end
function M.mark_segment(dirty, id) if dirty.segments ~= true then dirty.segments[id] = true end; dirty.segments_catalogue = true; dirty.summary = true; return dirty end
function M.mark_interface(dirty, id) if dirty.interfaces ~= true then dirty.interfaces[id] = true end; dirty.summary = true; return dirty end
function M.mark_domain(dirty, name) if dirty.domains ~= true then dirty.domains[name] = true end; dirty.summary = true; return dirty end

function M.clear_dirty(dirty)
	dirty.summary = false
	dirty.apply = false
	dirty.segments = {}
	dirty.interfaces = {}
	dirty.domains = {}
	dirty.segments_catalogue = false
	dirty.vlan_policy = false
	return dirty
end

function M.publish_dirty_now(conn, snapshot, dirty, published)
	published = published or M.new_state()
	dirty = dirty or M.mark_all(M.new_dirty_state())

	local ok, err
	if dirty.summary or not published.summary then
		ok, err = bus_cleanup.retain(conn, projection.summary_topic(), projection.summary(snapshot))
		if ok ~= true then return nil, err end
		published.summary = true
	end

	if dirty.apply or not published.apply then
		ok, err = bus_cleanup.retain(conn, projection.apply_topic(), projection.apply(snapshot))
		if ok ~= true then return nil, err end
		published.apply = true
	end

	ok, err = publish_map(conn, published.segments, snapshot.segments, dirty.segments, projection.segment_topic, projection.segment)
	if ok ~= true then return nil, err end

	if dirty.segments_catalogue or not published.segments_catalogue then
		ok, err = bus_cleanup.retain(conn, projection.segments_topic(), projection.segments(snapshot))
		if ok ~= true then return nil, err end
		published.segments_catalogue = true
	end

	if dirty.vlan_policy or not published.vlan_policy then
		ok, err = bus_cleanup.retain(conn, projection.vlan_policy_topic(), projection.vlan_policy(snapshot))
		if ok ~= true then return nil, err end
		published.vlan_policy = true
	end

	ok, err = publish_map(conn, published.interfaces, snapshot.interfaces, dirty.interfaces, projection.interface_topic, projection.interface)
	if ok ~= true then return nil, err end

	local dirty_domains = dirty.domains
	for i = 1, #DOMAIN_TOPICS do
		local name = DOMAIN_TOPICS[i]
		if dirty_domains == true or (type(dirty_domains) == 'table' and dirty_domains[name]) or not published.domains[name] then
			ok, err = bus_cleanup.retain(conn, projection.domain_topic(name), projection.domain(snapshot, name))
			if ok ~= true then return nil, err end
			published.domains[name] = true
		end
	end

	M.clear_dirty(dirty)
	return true, nil
end

function M.publish_all_now(conn, snapshot, published)
	local dirty = M.mark_all(M.new_dirty_state())
	return M.publish_dirty_now(conn, snapshot, dirty, published)
end

function M.cleanup_now(conn, published)
	if not published then return true, nil end

	for id in pairs(published.segments or {}) do
		bus_cleanup.unretain(conn, projection.segment_topic(id))
		published.segments[id] = nil
	end
	for id in pairs(published.interfaces or {}) do
		bus_cleanup.unretain(conn, projection.interface_topic(id))
		published.interfaces[id] = nil
	end
	for name in pairs(published.domains or {}) do
		bus_cleanup.unretain(conn, projection.domain_topic(name))
		published.domains[name] = nil
	end
	if published.summary then bus_cleanup.unretain(conn, projection.summary_topic()) end
	if published.apply then bus_cleanup.unretain(conn, projection.apply_topic()) end
	if published.segments_catalogue then bus_cleanup.unretain(conn, projection.segments_topic()) end
	if published.vlan_policy then bus_cleanup.unretain(conn, projection.vlan_policy_topic()) end
	published.summary = false
	published.apply = false
	published.segments_catalogue = false
	published.vlan_policy = false
	return true, nil
end

return M
