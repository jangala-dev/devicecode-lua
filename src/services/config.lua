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
--
-- Assumes cjson.safe is available.

local fibers       = require 'fibers'
local sleep        = require 'fibers.sleep'
local pulse        = require 'fibers.pulse'

local cjson        = require 'cjson.safe'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base         = require 'devicecode.service_base'

local M            = {}

local JSON_NULL    = cjson.null

local function strip_nulls(x, seen)
	if x == JSON_NULL then return nil end
	if type(x) ~= 'table' then return x end
	if getmetatable(x) ~= nil then return x end

	seen = seen or {}
	if seen[x] then return x end
	seen[x] = true

	for k, v in pairs(x) do
		local nv = strip_nulls(v, seen)
		if nv == nil then
			x[k] = nil
		else
			x[k] = nv
		end
	end
	return x
end

local function is_plain_table(x)
	return type(x) == 'table' and getmetatable(x) == nil
end

local function decode_blob_strict(blob)
	local decoded, jerr = cjson.decode(blob)
	if decoded == nil then
		return nil, 'json_decode_failed: ' .. tostring(jerr)
	end
	if not is_plain_table(decoded) then
		return nil, 'invalid_shape: root must be a table'
	end

	strip_nulls(decoded)

	local out = {}
	for svc, rec in pairs(decoded) do
		if type(svc) ~= 'string' or svc == '' then
			return nil, 'invalid_shape: service key must be non-empty string'
		end
		if not is_plain_table(rec) then
			return nil, 'invalid_shape: record must be a table for ' .. svc
		end
		if type(rec.rev) ~= 'number' then
			return nil, 'invalid_shape: rev must be a number for ' .. svc
		end
		if not is_plain_table(rec.data) then
			return nil, 'invalid_shape: data must be a table for ' .. svc
		end

		-- Require a schema discriminator in the data block.
		if type(rec.data.schema) ~= 'string' or rec.data.schema == '' then
			return nil, 'invalid_shape: data.schema must be a non-empty string for ' .. svc
		end

		out[svc] = { rev = math.floor(rec.rev), data = rec.data }
	end

	return out, nil
end

local function encode_blob(current)
	return cjson.encode(current) or '{}'
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'config', env = opts.env })

	svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
	svc:obs_log('info', 'service start() entered')
	svc:status('starting')

	svc:spawn_heartbeat(30.0, 'tick')

	local hal_announce, herr = svc:wait_for_hal({ timeout = 60, tick = 10 })
	if not hal_announce then
		svc:status('stopped', { reason = herr or 'no hal available' })
		svc:obs_log('error', { what = 'start_failed', err = tostring(herr or 'no hal') })
		return
	end

	local STATE_NS  = 'config'
	local STATE_KEY = 'services'

	-- current[svc] = { rev=int, data=table }
	local current   = {}

	local function publish_all_retained()
		local n = 0
		for sname, rec in pairs(current) do
			n = n + 1
			conn:retain({ 'config', sname }, rec)
		end
		svc:obs_event('publish_all', { services = n })
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

		local decoded, derr = decode_blob_strict(reply.data or '')
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

	local debounce_s     = 0.25
	local max_delay_s    = 5.0

	local retry_s        = 1.0
	local retry_max_s    = 30.0

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
		local blob = encode_blob(current)
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

	-- Strict set: payload must be { data = table }.
	local function set_service(service, payload, msg)
		if type(service) ~= 'string' or service == '' then
			return nil, 'invalid service'
		end
		if not is_plain_table(payload) or not is_plain_table(payload.data) then
			return nil, 'payload must be { data = table }'
		end

		local settings = payload.data

		if type(settings.schema) ~= 'string' or settings.schema == '' then
			return nil, 'payload.data.schema must be a non-empty string'
		end
		local okb, eerr = assert_no_extra_bags(settings, '$.payload.data')
		if not okb then
			return nil, eerr
		end

		local old = current[service]
		local next_rev = (old and type(old.rev) == 'number') and (math.floor(old.rev) + 1) or 1

		current[service] = { rev = next_rev, data = settings }
		conn:retain({ 'config', service }, current[service])

		svc:obs_event('set_applied', { service = service, rev = next_rev, id = msg and msg.id or nil })
		mark_dirty('set ' .. service)

		return true, nil
	end

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
		local ok, uerr = set_service(service, msg.payload, msg)

		-- Reply immediately: accepted != persisted.
		if msg.reply_to ~= nil then
			local reply = ok and { ok = true, persisted = false } or { ok = false, err = tostring(uerr) }
			conn:publish_one(msg.reply_to, reply, { id = msg.id })
		end

		if not ok then
			svc:obs_log('warn', { what = 'set_rejected', service = tostring(service), err = tostring(uerr) })
		end
	end
end

return M
