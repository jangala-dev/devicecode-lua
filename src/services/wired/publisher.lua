-- services/wired/publisher.lua
-- Immediate retained-state publication for Wired.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local retained_publish = require 'devicecode.support.retained_publish'
local projection = require 'services.wired.projection'

local M = {}

local function new_dirty_surfaces()
	return { all = false, ids = {} }
end

local function ensure_dirty(dirty)
	dirty = dirty or M.new_dirty_state()
	dirty.surfaces = dirty.surfaces or new_dirty_surfaces()
	dirty.surfaces.ids = dirty.surfaces.ids or {}
	dirty.counters = dirty.counters or new_dirty_surfaces()
	dirty.counters.ids = dirty.counters.ids or {}
	return dirty
end

function M.new_state()
	return { surfaces = {}, counters = {}, summary = nil, topology = nil, violations = nil }
end

function M.new_dirty_state()
	return { all = false, surfaces = new_dirty_surfaces(), counters = new_dirty_surfaces(), summary = false, topology = false, violations = false }
end

function M.mark_all(dirty)
	dirty = ensure_dirty(dirty)
	dirty.all = true
	dirty.surfaces.all = true
	dirty.counters.all = true
	dirty.summary = true
	dirty.topology = true
	dirty.violations = true
	return dirty
end

function M.mark_surface(dirty, id)
	dirty = ensure_dirty(dirty)
	if id ~= nil then dirty.surfaces.ids[id] = true end
	return dirty
end

function M.mark_counter(dirty, id)
	dirty = ensure_dirty(dirty)
	if id ~= nil then dirty.counters.ids[id] = true end
	return dirty
end

function M.mark_summary(dirty) dirty = ensure_dirty(dirty); dirty.summary = true; return dirty end
function M.mark_topology(dirty) dirty = ensure_dirty(dirty); dirty.topology = true; return dirty end
function M.mark_violations(dirty) dirty = ensure_dirty(dirty); dirty.violations = true; return dirty end

local function clear_dirty(dirty)
	if not dirty then return M.new_dirty_state() end
	dirty.all = false
	dirty.summary = false
	dirty.topology = false
	dirty.violations = false
	dirty.surfaces = new_dirty_surfaces()
	dirty.counters = new_dirty_surfaces()
	return dirty
end

local function retain_one(conn, published, key, topic, payload)
	local ok, err, changed = retained_publish.retain_if_changed(conn, published, key, topic, payload)
	if ok ~= true then return nil, err, changed end
	return true, nil, changed
end

local function publish_all_surfaces(conn, published, surfaces)
	return retained_publish.publish_map_changed(conn, published.surfaces, surfaces, projection.surface_topic, projection.surface)
end

local function publish_all_counters(conn, published, counters)
	return retained_publish.publish_map_changed(conn, published.counters, counters, projection.surface_counters_topic, projection.surface_counters)
end

local function publish_dirty_surfaces(conn, published, surfaces, dirty_surfaces)
	dirty_surfaces = dirty_surfaces or new_dirty_surfaces()
	if dirty_surfaces.all then return publish_all_surfaces(conn, published, surfaces) end
	local changed = 0
	for id in pairs(dirty_surfaces.ids or {}) do
		local rec = surfaces and surfaces[id] or nil
		if rec == nil then
			local ok, err, did = retained_publish.unretain_if_present(conn, published.surfaces, id, projection.surface_topic(id))
			if ok ~= true then return nil, err, changed end
			if did then changed = changed + 1 end
		else
			local ok, err, did = retained_publish.retain_if_changed(conn, published.surfaces, id, projection.surface_topic(id), projection.surface(rec))
			if ok ~= true then return nil, err, changed end
			if did then changed = changed + 1 end
		end
	end
	return true, nil, changed
end

local function publish_dirty_counters(conn, published, counters, dirty_counters)
	dirty_counters = dirty_counters or new_dirty_surfaces()
	if dirty_counters.all then return publish_all_counters(conn, published, counters) end
	local changed = 0
	for id in pairs(dirty_counters.ids or {}) do
		local rec = counters and counters[id] or nil
		if rec == nil then
			local ok, err, did = retained_publish.unretain_if_present(conn, published.counters, id, projection.surface_counters_topic(id))
			if ok ~= true then return nil, err, changed end
			if did then changed = changed + 1 end
		else
			local ok, err, did = retained_publish.retain_if_changed(conn, published.counters, id, projection.surface_counters_topic(id), projection.surface_counters(rec))
			if ok ~= true then return nil, err, changed end
			if did then changed = changed + 1 end
		end
	end
	return true, nil, changed
end

function M.publish_dirty_now(conn, snapshot, published, dirty)
	published = published or M.new_state()
	dirty = ensure_dirty(dirty)
	local changed = 0
	local ok, err, did
	if dirty.all or dirty.summary then
		ok, err, did = retain_one(conn, published, 'summary', projection.summary_topic(), projection.summary(snapshot))
		if ok ~= true then return nil, err, changed end
		if did then changed = changed + 1 end
	end
	if dirty.all or dirty.surfaces.all or next(dirty.surfaces.ids or {}) ~= nil then
		ok, err, did = publish_dirty_surfaces(conn, published, snapshot.surfaces, dirty.surfaces)
		if ok ~= true then return nil, err, changed end
		changed = changed + (did or 0)
	end
	if dirty.all or dirty.counters.all or next(dirty.counters.ids or {}) ~= nil then
		ok, err, did = publish_dirty_counters(conn, published, snapshot.counters, dirty.counters)
		if ok ~= true then return nil, err, changed end
		changed = changed + (did or 0)
	end
	if dirty.all or dirty.topology then
		ok, err, did = retain_one(conn, published, 'topology', projection.topology_topic(), projection.topology(snapshot))
		if ok ~= true then return nil, err, changed end
		if did then changed = changed + 1 end
	end
	if dirty.all or dirty.violations then
		ok, err, did = retain_one(conn, published, 'violations', projection.violations_topic(), projection.violations(snapshot))
		if ok ~= true then return nil, err, changed end
		if did then changed = changed + 1 end
	end
	clear_dirty(dirty)
	return true, nil, changed
end

function M.publish_all_now(conn, snapshot, published)
	return M.publish_dirty_now(conn, snapshot, published, M.mark_all(M.new_dirty_state()))
end

function M.cleanup_now(conn, published)
	if not published then return true, nil end
	for id in pairs(published.surfaces or {}) do bus_cleanup.unretain(conn, projection.surface_topic(id)); published.surfaces[id] = nil end
	for id in pairs(published.counters or {}) do bus_cleanup.unretain(conn, projection.surface_counters_topic(id)); published.counters[id] = nil end
	if published.summary ~= nil then bus_cleanup.unretain(conn, projection.summary_topic()) end
	if published.topology ~= nil then bus_cleanup.unretain(conn, projection.topology_topic()) end
	if published.violations ~= nil then bus_cleanup.unretain(conn, projection.violations_topic()) end
	published.summary, published.topology, published.violations = nil, nil, nil
	return true, nil
end

M.clear_dirty = clear_dirty
return M
