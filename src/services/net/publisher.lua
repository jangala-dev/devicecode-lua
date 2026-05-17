-- services/net/publisher.lua
-- Immediate retained-state publication for NET.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local projection = require 'services.net.projection'

local M = {}

local DOMAIN_TOPICS = {
	'addressing', 'dns', 'dhcp', 'firewall', 'routing',
	'wan', 'gsm', 'wan_runtime', 'shaping', 'vpn', 'diagnostics', 'observed', 'drift',
}

local function publish_map(conn, published, next_map, topic_fn, payload_fn)
	local seen = {}
	for id, rec in pairs(next_map or {}) do
		seen[id] = true
		local ok, err = bus_cleanup.retain(conn, topic_fn(id), payload_fn(rec))
		if ok ~= true then return nil, err end
		published[id] = true
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
	}
end

function M.publish_all_now(conn, snapshot, published)
	published = published or M.new_state()

	local ok, err = bus_cleanup.retain(conn, projection.summary_topic(), projection.summary(snapshot))
	if ok ~= true then return nil, err end
	published.summary = true

	ok, err = bus_cleanup.retain(conn, projection.apply_topic(), projection.apply(snapshot))
	if ok ~= true then return nil, err end
	published.apply = true

	ok, err = publish_map(conn, published.segments, snapshot.segments, projection.segment_topic, projection.segment)
	if ok ~= true then return nil, err end

	ok, err = publish_map(conn, published.interfaces, snapshot.interfaces, projection.interface_topic, projection.interface)
	if ok ~= true then return nil, err end

	for i = 1, #DOMAIN_TOPICS do
		local name = DOMAIN_TOPICS[i]
		ok, err = bus_cleanup.retain(conn, projection.domain_topic(name), projection.domain(snapshot, name))
		if ok ~= true then return nil, err end
		published.domains[name] = true
	end

	return true, nil
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
	published.summary = false
	published.apply = false
	return true, nil
end

return M
