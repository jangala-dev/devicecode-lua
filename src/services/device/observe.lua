-- services/device/observe.lua
--
-- Unified retained-fact / event / staleness observation helper.
-- It is intentionally small: providers configure facts/events/staleness and
-- this module emits logical provider-contract events.

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local model = require 'services.device.model'
local contract = require 'services.device.provider_contract'

local M = {}

local function open_fact_watch(conn, topic, opts)
	if type(topic) ~= 'table' then return nil end
	return conn:watch_retained(topic, {
		replay = true,
		queue_len = (opts and opts.fact_queue_len) or 16,
		full = (opts and opts.full) or 'drop_oldest',
	})
end

local function open_event_sub(conn, topic, opts)
	if type(topic) ~= 'table' then return nil end
	return conn:subscribe(topic, {
		queue_len = (opts and opts.event_queue_len) or 32,
		full = (opts and opts.event_full) or 'drop_oldest',
	})
end

local function close_all(t, method)
	for _, v in pairs(t or {}) do
		if v and type(v[method]) == 'function' then
			v[method](v)
		end
	end
end

local function recv_payload(ev)
	if ev == nil then return nil end
	return ev.payload or ev
end

local function make_choice(fact_watches, event_subs, stale_after_s)
	local arms = {}

	for fact_name, watch in pairs(fact_watches) do
		arms['fact:' .. fact_name] = watch:recv_op():wrap(function(ev, err)
			return { kind = 'fact', name = fact_name, ev = ev, err = err }
		end)
	end

	for event_name, sub in pairs(event_subs) do
		arms['event:' .. event_name] = sub:recv_op():wrap(function(msg, err)
			return { kind = 'event', name = event_name, msg = msg, err = err }
		end)
	end

	if type(stale_after_s) == 'number' and stale_after_s > 0 then
		arms._stale = sleep.sleep_op(stale_after_s):wrap(function()
			return { kind = 'stale' }
		end)
	end

	return fibers.named_choice(arms)
end

function M.run(ctx)
	local rec = ctx.rec or {}
	local conn = ctx.conn
	local emit = ctx.emit
	local opts = rec.provider_opts or {}

	local fact_watches = {}
	for fact_name, route in pairs(rec.facts or {}) do
		local watch = open_fact_watch(conn, route.watch_topic, opts)
		if watch then fact_watches[fact_name] = watch end
	end

	local event_subs = {}
	for event_name, route in pairs(rec.events or {}) do
		local sub = open_event_sub(conn, route.subscribe_topic, opts)
		if sub then event_subs[event_name] = sub end
	end

	if next(fact_watches) == nil and next(event_subs) == nil then
		contract.emit(emit, { tag = 'source_down', reason = 'no_observation_topics' })
		return
	end

	fibers.current_scope():finally(function()
		close_all(fact_watches, 'unwatch')
		close_all(event_subs, 'unsubscribe')
	end)

	local stale_after_s = tonumber(opts.stale_after_s or opts.stale_after)

	while true do
		local _which, item = fibers.perform(make_choice(fact_watches, event_subs, stale_after_s))

		if not item then
			contract.emit(emit, { tag = 'source_down', reason = 'observer_closed' })
			return
		end

		if item.kind == 'stale' then
			contract.emit(emit, { tag = 'source_down', reason = 'stale' })

		elseif item.kind == 'fact' then
			local ev = item.ev
			if not ev then
				contract.emit(emit, { tag = 'source_down', reason = tostring(item.err or (item.name .. ':closed')) })
				return
			end

			if ev.op == 'retain' then
				contract.emit(emit, {
					tag = 'fact_changed',
					fact = item.name,
					payload = model.copy_value(recv_payload(ev)),
				})
			elseif ev.op == 'unretain' then
				contract.emit(emit, {
					tag = 'fact_changed',
					fact = item.name,
					payload = nil,
				})
			end

		elseif item.kind == 'event' then
			if not item.msg then
				contract.emit(emit, { tag = 'source_down', reason = tostring(item.err or (item.name .. ':closed')) })
				return
			end
			contract.emit(emit, {
				tag = 'event_seen',
				event = item.name,
				payload = model.copy_value(recv_payload(item.msg)),
				raw = model.copy_value(item.msg),
			})
		end
	end
end

return M
