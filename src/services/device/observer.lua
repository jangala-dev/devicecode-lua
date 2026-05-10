-- services/device/observer.lua
--
-- Component observer worker. Owns raw retained watches and event subscriptions
-- for one component in one generation, and emits semantic observation events.

local fibers      = require 'fibers'
local sleep       = require 'fibers.sleep'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local queue       = require 'devicecode.support.queue'
local model       = require 'services.device.model'
local backpressure = require 'services.device.backpressure'

local M = {}

local function emit_required(tx, ev)
	return queue.assert_admit_required(tx, ev, 'device_observation_event_report_failed', 3)
end

local function close_all(conn, set, method)
	for _, item in pairs(set or {}) do
		if method == 'unwatch_retained' then
			bus_cleanup.unwatch_retained(conn, item)
		elseif method == 'unsubscribe' then
			bus_cleanup.unsubscribe(conn, item)
		else
			bus_cleanup.close_feed(item)
		end
	end
end

local function recv_payload(ev)
	if ev == nil then return nil end
	if type(ev) == 'table' and ev.payload ~= nil then return ev.payload end
	return ev
end


local function normalise_with_component(rec, kind, name, payload)
	local mod = type(rec) == 'table' and rec.module or nil
	local fn
	if type(mod) == 'table' then
		if kind == 'fact' then
			fn = mod.normalise_fact or mod.normalize_fact
		else
			fn = mod.normalise_event or mod.normalize_event
		end
	end

	if type(fn) ~= 'function' then
		return model.copy_value(payload), nil
	end

	local ok, value, err = pcall(fn, name, payload, rec)
	if not ok then return nil, tostring(value) end
	return value, err
end

local function open_fact_watch(conn, route, opts)
	return bus_cleanup.watch_retained(conn, route.watch_topic, {
		queue_len = opts.queue_len or opts.fact_queue_len or backpressure.policy.observer_feeds.default_len,
		full = opts.full or backpressure.policy.observer_feeds.full,
		replay = true,
	})
end

local function open_event_sub(conn, route, opts)
	return bus_cleanup.subscribe(conn, route.subscribe_topic, {
		queue_len = opts.queue_len or opts.event_queue_len or backpressure.policy.observer_feeds.default_len,
		full = opts.full or backpressure.policy.observer_feeds.full,
	})
end

local function freshness_predicate(rec, fact_watches, event_subs)
	local required = {}
	local required_count = 0
	for _, name in ipairs(rec.required_facts or {}) do
		if type(name) == 'string' and name ~= '' and fact_watches[name] then
			required[name] = true
			required_count = required_count + 1
		end
	end

	local has_facts = next(fact_watches) ~= nil
	local has_events = next(event_subs) ~= nil

	return function (item)
		if not item then return false end
		if item.kind == 'fact' then
			if required_count == 0 then return true end
			return required[item.name] == true
		end
		if item.kind == 'event' then
			return (not has_facts) and has_events
		end
		return false
	end
end

local function make_choice(fact_watches, event_subs, stale_deadline)
	local arms = {}

	for fact_name, watch in pairs(fact_watches) do
		arms['fact:' .. fact_name] = watch:recv_op():wrap(function (ev, err)
			return { kind = 'fact', name = fact_name, ev = ev, err = err }
		end)
	end

	for event_name, sub in pairs(event_subs) do
		arms['event:' .. event_name] = sub:recv_op():wrap(function (msg, err)
			return { kind = 'event', name = event_name, msg = msg, err = err }
		end)
	end

	if type(stale_deadline) == 'number' then
		arms._stale = sleep.sleep_until_op(stale_deadline):wrap(function ()
			return { kind = 'stale' }
		end)
	end

	return fibers.named_choice(arms):wrap(function (_, item)
		return item
	end)
end

function M.run(scope, ctx)
	ctx = ctx or {}
	local rec = ctx.component or ctx.rec or {}
	local conn = assert(ctx.conn, 'device observer requires conn')
	local tx = assert(ctx.tx, 'device observer requires tx')
	local generation = assert(ctx.generation, 'device observer requires generation')
	local component_id = assert(ctx.component_id or rec.id or rec.name, 'device observer requires component_id')
	local opts = rec.observe_opts or {}

	local function emit(ev)
		ev.kind = ev.kind or 'component_observation'
		ev.generation = generation
		ev.component = ev.component or component_id
		emit_required(tx, ev)
	end

	local fact_watches = {}
	local event_subs = {}

	-- Ownership is established before the first raw handle is opened.  If any
	-- later source-down report or open step fails, already-opened handles remain
	-- owned by this observer scope and are released by its finaliser.
	scope:finally(function ()
		close_all(conn, fact_watches, 'unwatch_retained')
		close_all(conn, event_subs, 'unsubscribe')
	end)

	for fact_name, route in pairs(rec.facts or {}) do
		local watch, err = open_fact_watch(conn, route, opts)
		if watch then
			fact_watches[fact_name] = watch
		else
			emit({ tag = 'source_down', reason = tostring(err or ('watch_failed:' .. fact_name)) })
		end
	end

	for event_name, route in pairs(rec.events or {}) do
		local sub, err = open_event_sub(conn, route, opts)
		if sub then
			event_subs[event_name] = sub
		else
			emit({ tag = 'source_down', reason = tostring(err or ('subscribe_failed:' .. event_name)) })
		end
	end

	if next(fact_watches) == nil and next(event_subs) == nil then
		emit({ tag = 'source_down', reason = 'no_observation_topics' })
		return { reason = 'no_observation_topics' }
	end

	local stale_after_s = tonumber(opts.stale_after_s or opts.stale_after)
	local stale_deadline = (type(stale_after_s) == 'number' and stale_after_s > 0) and (fibers.now() + stale_after_s) or nil
	local stale_latched = false
	local refreshes_freshness = freshness_predicate(rec, fact_watches, event_subs)

	while true do
		local item = fibers.perform(make_choice(fact_watches, event_subs, stale_deadline))
		if not item then
			emit({ tag = 'source_down', reason = 'observer_closed' })
			return { reason = 'observer_closed' }
		end

		if item.kind == 'stale' then
			if not stale_latched then
				stale_latched = true
				stale_deadline = nil
				emit({ tag = 'source_down', reason = 'stale' })
			end
		elseif item.kind == 'fact' then
			if not item.ev then
				emit({ tag = 'source_down', reason = tostring(item.err or (item.name .. ':closed')) })
				return { reason = 'fact_closed', fact = item.name }
			end

			if refreshes_freshness(item) then
				stale_latched = false
				stale_deadline = (type(stale_after_s) == 'number' and stale_after_s > 0) and (fibers.now() + stale_after_s) or nil
			end

			if item.ev.op == 'retain' then
				local raw = recv_payload(item.ev)
				local payload, nerr = normalise_with_component(rec, 'fact', item.name, raw)
				if nerr ~= nil then
					emit({ tag = 'source_down', reason = 'bad_fact:' .. item.name .. ':' .. tostring(nerr) })
				else
					emit({ tag = 'fact_retained', fact = item.name, payload = payload, raw = model.copy_value(raw) })
				end
			elseif item.ev.op == 'unretain' then
				emit({ tag = 'fact_unretained', fact = item.name })
			else
				local raw = recv_payload(item.ev)
				local payload, nerr = normalise_with_component(rec, 'fact', item.name, raw)
				if nerr ~= nil then
					emit({ tag = 'source_down', reason = 'bad_fact:' .. item.name .. ':' .. tostring(nerr) })
				else
					emit({ tag = 'fact_retained', fact = item.name, payload = payload, raw = model.copy_value(raw) })
				end
			end
		elseif item.kind == 'event' then
			if not item.msg then
				emit({ tag = 'source_down', reason = tostring(item.err or (item.name .. ':closed')) })
				return { reason = 'event_closed', event = item.name }
			end

			if refreshes_freshness(item) then
				stale_latched = false
				stale_deadline = (type(stale_after_s) == 'number' and stale_after_s > 0) and (fibers.now() + stale_after_s) or nil
			end

			local raw = recv_payload(item.msg)
			local payload, nerr = normalise_with_component(rec, 'event', item.name, raw)
			if nerr ~= nil then
				emit({ tag = 'source_down', reason = 'bad_event:' .. item.name .. ':' .. tostring(nerr) })
			else
				emit({
					tag = 'event',
					event = item.name,
					payload = payload,
					raw = model.copy_value(item.msg),
				})
			end
		end
	end
end

return M
