-- services/device/providers/status_watch.lua
--
-- Default device component provider.
--
-- Behaviour:
--   * if a status get route exists, attempt one initial fetch
--   * if a status watch route exists, subscribe and emit subsequent changes
--   * if the watch closes, emit source_down and stop
--
-- Policy note:
--   * initial fetch failure is intentionally non-fatal
--   * if the one-shot fetch fails or times out, the provider still proceeds to
--     the watch stream when one is available
--   * this keeps steady-state observation preferred over failing fast on a
--     transient startup/status-read problem
--
-- Boundary note:
--   * ctx.emit(...) stamps component/generation at the observer boundary
--   * providers therefore emit only logical event contents

local fibers = require 'fibers'
local proxy = require 'services.device.proxy'

local M = {}

local function initial_status_op(ctx)
	local rec = ctx.rec
	local get_topic = rec.channels and rec.channels.status and rec.channels.status.get_topic or nil
	if type(get_topic) ~= 'table' then
		return fibers.always(nil, 'no_initial_status')
	end
	return proxy.fetch_status_op(ctx.conn, rec, {}, 0.5)
end

function M.run(ctx)
	local conn = ctx.conn
	local rec = ctx.rec
	local emit = ctx.emit

	local watch_topic = rec.channels and rec.channels.status and rec.channels.status.watch_topic or nil

	local value, _ = fibers.perform(initial_status_op(ctx))
	if value ~= nil then
		emit({ tag = 'raw_changed', payload = value })
	end

	if type(watch_topic) ~= 'table' then
		return
	end

	local sub = conn:subscribe(watch_topic, { queue_len = 16, full = 'drop_oldest' })

	fibers.current_scope():finally(function()
		sub:unsubscribe()
	end)

	while true do
		local msg, err = fibers.perform(sub:recv_op())
		if msg then
			emit({
				tag = 'raw_changed',
				payload = msg.payload or msg,
			})
		else
			emit({
				tag = 'source_down',
				reason = tostring(err or 'closed'),
			})
			return
		end
	end
end

return M
