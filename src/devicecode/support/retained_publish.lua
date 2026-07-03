-- devicecode/support/retained_publish.lua
--
-- Idempotent retained-state publication helpers.  These helpers are for
-- retained state/meta/capability projections, not event streams: they suppress
-- unchanged retains so retained watchers are not woken for identical payloads.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local tablex = require 'shared.table'

local M = {}

local function key_of(key)
	if key ~= nil then return key end
	return '_'
end

local function copy(v) return tablex.deep_copy(v) end

function M.retain_if_changed(conn, cache, key, topic, payload, opts)
	cache = cache or {}
	local k = key_of(key)
	if cache[k] ~= nil and tablex.deep_equal(cache[k], payload) then
		return true, nil, false
	end
	local ok, err = bus_cleanup.retain(conn, topic, payload, opts)
	if ok ~= true then return nil, err, false end
	cache[k] = copy(payload)
	return true, nil, true
end

function M.unretain_if_present(conn, cache, key, topic, opts)
	cache = cache or {}
	local k = key_of(key)
	if cache[k] == nil then return true, nil, false end
	local ok, err = bus_cleanup.unretain(conn, topic, opts)
	if ok ~= true then return nil, err, false end
	cache[k] = nil
	return true, nil, true
end

function M.publish_map_changed(conn, cache, next_map, topic_fn, payload_fn, opts)
	cache = cache or {}
	local seen = {}
	local changed = 0
	for id, rec in pairs(next_map or {}) do
		seen[id] = true
		local payload = payload_fn(rec, id)
		local ok, err, did = M.retain_if_changed(conn, cache, id, topic_fn(id), payload, opts)
		if ok ~= true then return nil, err, changed end
		if did then changed = changed + 1 end
	end
	local removed = {}
	for id in pairs(cache) do
		if not seen[id] then removed[#removed + 1] = id end
	end
	for i = 1, #removed do
		local id = removed[i]
		local ok, err, did = M.unretain_if_present(conn, cache, id, topic_fn(id), opts)
		if ok ~= true then return nil, err, changed end
		if did then changed = changed + 1 end
	end
	return true, nil, changed
end

M.copy = copy
return M
