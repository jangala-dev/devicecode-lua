-- services/config.lua
--
-- Config service (strict protocol):
--  - discovers HAL via retained svc/hal/announce
--  - reads a single JSON blob from HAL (string) in strict shape:
--        { <svc>: { rev: int, data: table }, ... }
--  - publishes retained config/<svc> with { rev=int, data=table }
--  - accepts updates only on:
--        config/<svc>/set with payload { data = table }
--
-- Persisted state location (within HAL):
--   ns  = "config"
--   key = "services"

-- services/config.lua

local fibers       = require 'fibers'
local sleep        = require 'fibers.sleep'
local pulse        = require 'fibers.pulse'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base         = require 'devicecode.service_base'
local codec        = require 'services.config.codec'
local state        = require 'services.config.state'

local M            = {}

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'config', env = opts.env })

	local timings = opts.timings or {}

	local function numopt(name, default)
		local v = timings[name]
		return (type(v) == 'number') and v or default
	end

	local hal_wait_timeout_s     = numopt('hal_wait_timeout_s', 60)
	local hal_wait_tick_s        = numopt('hal_wait_tick_s', 10)
	local heartbeat_s            = numopt('heartbeat_s', 30.0)

	local persist_debounce_s     = numopt('persist_debounce_s', 0.25)
	local persist_max_delay_s    = numopt('persist_max_delay_s', 5.0)
	local persist_retry_initial_s = numopt('persist_retry_initial_s', 1.0)
	local persist_retry_max_s    = numopt('persist_retry_max_s', 30.0)

	svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
	svc:obs_log('info', 'service start() entered')
	svc:status('starting')

	svc:spawn_heartbeat(heartbeat_s, 'tick')

	local hal_announce, herr = svc:wait_for_hal({
		timeout = hal_wait_timeout_s,
		tick    = hal_wait_tick_s,
	})

	if not hal_announce then
		local err = herr or 'no hal available'
		svc:status('failed', { reason = err })
		svc:obs_log('error', { what = 'start_failed', err = tostring(err) })
		error(('config: failed to discover HAL: %s'):format(tostring(err)), 0)
	end

	local STATE_NS  = 'config'
	local STATE_KEY = 'services'

	-- current[svc] = { rev=int, data=table }
	local current   = {}

	local function publish_all_retained()
		return state.publish_all_retained(conn, svc, current)
	end

	local function load_from_hal()
		svc:obs_event('load_begin', { ns = STATE_NS, key = STATE_KEY })

		local reply, err = svc:hal_call('read_state', { ns = STATE_NS, key = STATE_KEY }, 2.0)
		if not reply then
			svc:obs_log('error', { what = 'load_failed', err = tostring(err) })
			current = {}
			publish_all_retained()
			svc:obs_event('load_end', { ok = false, reason = 'call_failed' })
			return true
		end
		if reply.ok ~= true then
			svc:obs_log('error', { what = 'load_failed', err = tostring(reply.err or 'hal read failed') })
			current = {}
			publish_all_retained()
			svc:obs_event('load_end', { ok = false, reason = 'hal_error' })
			return true
		end
		if reply.found ~= true then
			svc:obs_log('warn', { what = 'load_missing', ns = STATE_NS, key = STATE_KEY })
			current = {}
			publish_all_retained()
			svc:obs_event('load_end', { ok = true, services = 0 })
			return true
		end

		local decoded, derr = codec.decode_blob_strict(reply.data or '')
		if not decoded then
			svc:status('degraded', { reason = 'invalid config JSON', err = tostring(derr) })
			svc:obs_log('error', { what = 'decode_failed', err = tostring(derr) })
			current = {}
			publish_all_retained()
			svc:obs_event('load_end', { ok = false, reason = tostring(derr) })
			return true
		end

		current = decoded
		publish_all_retained()
		svc:obs_event('load_end', { ok = true })
		return true
	end

	load_from_hal()

	-- Debounced persistence worker (coalesces writes).
	local p              = pulse.new()
	local dirty          = false
	local flush_at       = math.huge
	local flush_deadline = math.huge

	local debounce_s     = persist_debounce_s
	local max_delay_s    = persist_max_delay_s

	local retry_s        = persist_retry_initial_s
	local retry_max_s    = persist_retry_max_s

	local function mark_dirty(reason)
		local n = svc:now()
		dirty = true
		flush_at = n + debounce_s
		if flush_deadline == math.huge then
			flush_deadline = n + max_delay_s
		end
		p:signal()
		svc:obs_event('persist_dirty', { reason = reason, at = svc:wall(), ts = svc:now() })
	end

	local function persist_snapshot(reason)
		local blob, berr = codec.encode_blob(current)
		if not blob then
			svc:obs_log('error', { what = 'persist_encode_failed', err = tostring(berr) })
			svc:obs_event('persist_end', { ok = false, err = tostring(berr), phase = 'encode' })
			return nil, berr
		end

		svc:obs_event('persist_begin', { ns = STATE_NS, key = STATE_KEY, reason = reason, bytes = #blob })

		local reply, err = svc:hal_call('write_state', { ns = STATE_NS, key = STATE_KEY, data = blob }, 4.0)
		if not reply then
			svc:obs_log('error', { what = 'persist_failed', err = tostring(err) })
			svc:obs_event('persist_end', { ok = false, err = tostring(err) })
			return nil, err
		end
		if reply.ok ~= true then
			local e = tostring(reply.err or 'hal write failed')
			svc:obs_log('error', { what = 'persist_failed', err = e })
			svc:obs_event('persist_end', { ok = false, err = e })
			return nil, e
		end

		svc:obs_event('persist_end', { ok = true })
		return true, nil
	end

	fibers.spawn(function()
		local seen = p:version()
		while true do
			if dirty then
				local due = math.min(flush_at, flush_deadline)
				local dt = due - svc:now()
				if dt <= 0 then
					local ok, err = persist_snapshot('debounced_flush')
					if ok then
						dirty = false
						flush_at = math.huge
						flush_deadline = math.huge
						retry_s = 1.0
						svc:status('running')
					else
						local n = svc:now()
						flush_at = n + retry_s
						flush_deadline = math.min(flush_deadline, n + max_delay_s)
						retry_s = math.min(retry_s * 2, retry_max_s)
						svc:status('degraded', { reason = 'persist_failed', err = tostring(err) })
					end
				else
					local which, a, b = perform(named_choice {
						changed = p:changed_op(seen),
						timer   = sleep.sleep_op(dt):wrap(function() return true end),
					})
					if which == 'changed' then
						local v, r = a, b
						if v == nil and r ~= nil then return end
						seen = v or seen
					end
				end
			else
				local v, r = perform(p:changed_op(seen))
				if v == nil and r ~= nil then return end
				seen = v or seen
			end
		end
	end)

	local sub_set = conn:subscribe({ 'config', '+', 'set' }, { queue_len = 50, full = 'drop_oldest' })
	svc:obs_log('info', 'subscribed to config/+/set')

	svc:status('running')
	svc:obs_log('info', 'service running')

	while true do
		local msg, err = perform(sub_set:recv_op())
		if not msg then
			svc:status('stopped', { reason = err })
			svc:obs_log('warn', { what = 'subscription_ended', err = tostring(err) })
			return
		end

		local service = msg.topic and msg.topic[2]
		local ok, uerr = state.set_service(current, conn, svc, mark_dirty, service, msg.payload, msg)

		-- Reply immediately: accepted != persisted.
		if msg.reply_to ~= nil then
			local reply = ok and { ok = true, persisted = false } or { ok = false, err = tostring(uerr) }
			conn:publish(msg.reply_to, reply, { id = msg.id })
		end

		if not ok then
			svc:obs_log('warn', { what = 'set_rejected', service = tostring(service), err = tostring(uerr) })
		end
	end
end

return M
