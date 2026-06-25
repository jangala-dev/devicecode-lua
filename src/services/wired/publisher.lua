-- services/wired/publisher.lua
-- Immediate retained-state publication for Wired.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local projection = require 'services.wired.projection'

local M = {}

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
	return { surfaces = {}, summary = false, topology = false, violations = false }
end

function M.publish_all_now(conn, snapshot, published)
	published = published or M.new_state()
	local ok, err = bus_cleanup.retain(conn, projection.summary_topic(), projection.summary(snapshot))
	if ok ~= true then return nil, err end
	published.summary = true
	ok, err = publish_map(conn, published.surfaces, snapshot.surfaces, projection.surface_topic, projection.surface)
	if ok ~= true then return nil, err end
	ok, err = bus_cleanup.retain(conn, projection.topology_topic(), projection.topology(snapshot))
	if ok ~= true then return nil, err end
	published.topology = true
	ok, err = bus_cleanup.retain(conn, projection.violations_topic(), projection.violations(snapshot))
	if ok ~= true then return nil, err end
	published.violations = true
	return true, nil
end

function M.cleanup_now(conn, published)
	if not published then return true, nil end
	for id in pairs(published.surfaces or {}) do bus_cleanup.unretain(conn, projection.surface_topic(id)); published.surfaces[id] = nil end
	if published.summary then bus_cleanup.unretain(conn, projection.summary_topic()) end
	if published.topology then bus_cleanup.unretain(conn, projection.topology_topic()) end
	if published.violations then bus_cleanup.unretain(conn, projection.violations_topic()) end
	published.summary, published.topology, published.violations = false, false, false
	return true, nil
end

return M
