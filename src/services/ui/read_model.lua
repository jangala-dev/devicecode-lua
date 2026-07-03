-- services/ui/read_model.lua
--
-- Read-model component assembly.
--
-- Fabric-grade split:
--   * read_model_store.lua   : pure retained-state projection/model
--   * read_model_watches.lua : local watch owner and fanout boundary
--
-- This module wires retained bus feeds into the store/watch owner. It remains as
-- the public read-model entry point for UI callers.

local fibers      = require 'fibers'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local store_mod   = require 'services.ui.read_model_store'
local watches_mod = require 'services.ui.read_model_watches'
local topics      = require 'services.ui.topics'

local M = {}


local function event_topic(ev)
	if type(ev) ~= 'table' then return nil end
	return ev.topic
end

local function topic_is_excluded(topic, excluded_patterns, opts)
	opts = opts or {}
	if type(topic) ~= 'table' then return false end
	for _, pattern in ipairs(excluded_patterns or {}) do
		if store_mod.match_topic(pattern, topic, opts.s_wild or '+', opts.m_wild or '#') then
			return true
		end
	end
	return false
end

local function should_ingest_event(ev, opts)
	opts = opts or {}
	if type(ev) ~= 'table' then return true end
	if ev.op == 'replay_done' then return true end
	local topic = event_topic(ev)
	local excluded = opts.exclude_patterns or opts.excluded_patterns or topics.default_excluded_retained_patterns()
	return not topic_is_excluded(topic, excluded, opts)
end

local function start_feed_owner(scope, target, conn, pattern, opts)
	local watch, err = bus_cleanup.watch_retained(conn, pattern, {
		replay = true,
		queue_len = opts.feed_queue_len or 64,
		full = opts.feed_full or 'reject_newest',
	})
	if not watch then
		return nil, err or 'watch_retained failed'
	end

	scope:finally(function ()
		bus_cleanup.unwatch_retained(conn, watch)
	end)

	local ok, spawn_err = fibers.spawn(function ()
		while true do
			local ev, recv_err = fibers.perform(watch:recv_op())
			if ev == nil then
				error(recv_err or 'read model retained feed closed', 0)
			end
			if should_ingest_event(ev, opts) then
				local changed, _msg, _op_name, ingest_err = target:ingest(ev)
				if changed == nil then
					error(ingest_err or 'read model ingest failed', 0)
				end
			end
		end
	end)
	if not ok then
		bus_cleanup.unwatch_retained(conn, watch)
		return nil, spawn_err
	end

	return true, nil
end

--- Create a pure retained-state projection store.
function M.new(opts)
	return store_mod.new(opts)
end

--- Create a local watch owner for an existing store.
function M.new_watches(store, opts)
	return watches_mod.new(store, opts)
end

--- Start retained-feed owners inside an already-created read-model scope.
---
--- opts.model is the pure projection store.
--- opts.watch_owner is the local watch fanout owner.
---
--- Returns the store and watch owner immediately; feed owners run as child
--- fibres in the same scope.
function M.start(scope, conn, opts)
	opts = opts or {}
	local store = opts.model or M.new(opts)
	local watch_owner = opts.watch_owner
	if watch_owner == nil then
		watch_owner = M.new_watches(store, opts)
	end

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'read_model_closed'
		watch_owner:terminate(reason)
		store:terminate(reason)
	end)

	if conn ~= nil then
		local patterns = opts.patterns or topics.default_retained_patterns(opts)
		for _, pattern in ipairs(patterns) do
			local ok, err = start_feed_owner(scope, watch_owner, conn, pattern, opts)
			if not ok then error(err or 'read_model feed start failed', 2) end
		end
	end

	return store, watch_owner
end

M.store = store_mod
M.watches = watches_mod
M.Store = store_mod.Store
M.WatchOwner = watches_mod.WatchOwner
M.Watch = watches_mod.Watch
M.match_topic = store_mod.match_topic
M._test = {
	should_ingest_event = should_ingest_event,
	topic_is_excluded = topic_is_excluded,
}

return M
