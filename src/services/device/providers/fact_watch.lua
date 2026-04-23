-- services/device/providers/fact_watch.lua
--
-- Generic split-fact device provider.
--
-- Canonical behaviour:
--   * one retained watch per configured fact topic
--   * one provider loop multiplexes all recv_op()s using named_choice
--   * emits fact_changed/source_down to the device shell
--
-- This provider is intentionally generic and is used for fact-backed
-- components such as MCU and CM5.

local fibers = require 'fibers'
local model = require 'services.device.model'

local M = {}

local function open_watch(conn, topic)
	if type(topic) ~= 'table' then return nil end
	return conn:watch_retained(topic, { replay = true, queue_len = 16, full = 'drop_oldest' })
end

local function next_fact_event_op(watches)
	local arms = {}
	for fact_name, watch in pairs(watches) do
		arms[fact_name] = watch:recv_op()
	end
	return fibers.named_choice(arms)
end

local function recv_payload(ev)
	if ev == nil then return nil end
	return ev.payload or ev
end

function M.run(ctx)
	local rec = ctx.rec
	local emit = ctx.emit
	local conn = ctx.conn

	local watches = {}
	for fact_name, route in pairs(rec.facts or {}) do
		local watch = open_watch(conn, route.watch_topic)
		if watch then
			watches[fact_name] = watch
		end
	end

	if next(watches) == nil then
		emit({ tag = 'source_down', reason = 'no_fact_watch_topics' })
		return
	end

	fibers.current_scope():finally(function()
		for _, watch in pairs(watches) do
			watch:unwatch()
		end
	end)

	while true do
		local fact_name, ev, err = fibers.perform(next_fact_event_op(watches))
		if not ev then
			emit({ tag = 'source_down', reason = tostring(err or (fact_name .. ':closed')) })
			return
		end

		if ev.op == 'retain' then
			emit({
				tag = 'fact_changed',
				fact = fact_name,
				payload = model.copy_value(recv_payload(ev)),
			})
		elseif ev.op == 'unretain' then
			emit({
				tag = 'fact_changed',
				fact = fact_name,
				payload = nil,
			})
		end
	end
end

return M
