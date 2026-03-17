-- services/time.lua
--
-- Time service:
--  - discovers the first HAL time capability via {'cap','time','+','meta','source'}
--  - consumes retained state + sync/unsync events from that capability
--  - publishes retained {'svc','time','synced'} for system-wide time trust state
--  - nudges fibers alarm wall-clock handling when sync transitions occur

local fibers = require "fibers"
local op = require "fibers.op"
local alarm = require "fibers.alarm"
local time_utils = require "fibers.utils.time"

local log = require "services.log"

local perform = fibers.perform
local now = fibers.now

local M = {}

---@return table
local function t(...)
	return { ... }
end

---@param conn Connection
---@param name string
---@param state string
---@param extra table?
---@return nil
local function publish_status(conn, name, state, extra)
	local payload = { state = state, ts = now() }
	if type(extra) == 'table' then
		for k, v in pairs(extra) do payload[k] = v end
	end
	log.trace(("TIME: service status -> %s"):format(tostring(state)))
	conn:retain(t('svc', name, 'status'), payload)
end

---@param conn Connection
---@param synced boolean
---@return nil
local function publish_synced(conn, synced)
	conn:retain(t('svc', 'time', 'synced'), synced)
end

---@param conn Connection
---@param event_name 'synced'|'unsynced'
---@param payload table?
---@return nil
local function publish_transition_event(conn, event_name, payload)
	conn:publish(t('svc', 'time', 'event', event_name), payload or {})
end

---@param payload any
---@return boolean? synced
local function synced_from_state_payload(payload)
	if type(payload) ~= 'table' then return nil end
	if type(payload.synced) ~= 'boolean' then return nil end
	return payload.synced
end

---@param state table
---@param conn Connection
---@param is_synced boolean
---@param payload table?
---@return nil
local function apply_sync_state(state, conn, is_synced, payload)
	if state.current_synced ~= is_synced then
		log.info((
			"TIME: sync state transition %s -> %s"
		):format(tostring(state.current_synced), tostring(is_synced)))
		publish_synced(conn, is_synced)
		if is_synced then
			publish_transition_event(conn, 'synced', payload)
		else
			publish_transition_event(conn, 'unsynced', payload)
		end
		state.current_synced = is_synced
	end

	-- New fibers core has set_time_source/time_changed instead of
	-- install_alarm_handler/clock_synced/clock_desynced.
	if is_synced then
		if not state.time_source_installed then
			log.info("TIME: installing alarm time source from realtime clock")
			local ok, err = pcall(alarm.set_time_source, time_utils.realtime)
			if ok then
				state.time_source_installed = true
				log.info("TIME: alarm time source installed")
			else
				log.warn("TIME: failed to set alarm time source:", tostring(err))
			end
		else
			alarm.time_changed()
		end
	end
end

---@param conn Connection
---@param cap_id CapabilityId
---@return nil
local function monitor_capability(conn, cap_id)
	log.info(("TIME: starting monitor for capability id=%s"):format(tostring(cap_id)))
	local sub_state = conn:subscribe(t('cap', 'time', cap_id, 'state', 'synced'), {
		queue_len = 10,
		full = 'drop_oldest',
	})
	local sub_synced = conn:subscribe(t('cap', 'time', cap_id, 'event', 'synced'), {
		queue_len = 20,
		full = 'drop_oldest',
	})
	local sub_unsynced = conn:subscribe(t('cap', 'time', cap_id, 'event', 'unsynced'), {
		queue_len = 20,
		full = 'drop_oldest',
	})

	local state = {
		---@type boolean?
		current_synced = nil,
		---@type boolean
		time_source_installed = false,
	}

	-- Read retained initial state once, then rely on events for transitions.
	do
		local msg, err = perform(sub_state:recv_op())
		if msg then
			log.info("TIME: received initial retained sync state")
			local is_synced = synced_from_state_payload(msg.payload)
			if is_synced ~= nil then
				apply_sync_state(state, conn, is_synced, msg.payload)
			else
				log.warn("TIME: initial retained state payload missing boolean synced field")
			end
		else
			log.warn("TIME: failed to read initial state:", err)
		end
		sub_state:unsubscribe()
	end

	while true do
		local which, msg, err = perform(op.named_choice({
			synced = sub_synced:recv_op(),
			unsynced = sub_unsynced:recv_op(),
		}))

		if not msg then
			log.warn("TIME: capability monitor subscription closed:", err)
			return
		end

		if which == 'synced' then
			apply_sync_state(state, conn, true, msg.payload)
		elseif which == 'unsynced' then
			apply_sync_state(state, conn, false, msg.payload)
		else
			log.warn("TIME: unknown event source in monitor loop:", tostring(which))
		end
	end
end

---@param conn Connection
---@param opts table?
---@return nil
function M.start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'time'
	log.trace("TIME: starting")

	publish_status(conn, name, 'starting')

	fibers.current_scope():finally(function()
		local st, primary = fibers.current_scope():status()
		if st == 'failed' then
			log.error(("TIME: scope failed - %s"):format(tostring(primary)))
		end
		publish_status(conn, name, 'stopped', { reason = primary or st })
	end)

	local sub_meta = conn:subscribe(t('cap', 'time', '+', 'meta', 'source'), {
		queue_len = 10,
		full = 'drop_oldest',
	})
	log.trace("TIME: subscribed to time capability meta announcements")

	publish_status(conn, name, 'running')

	while true do
		local msg, err = perform(sub_meta:recv_op())
		if not msg then
			sub_meta:unsubscribe()
			log.warn("TIME: capability discovery subscription closed:", err)
			return
		end

		local topic = msg.topic
		local cap_id = topic and topic[3]
		if cap_id ~= nil then
			sub_meta:unsubscribe()
			log.trace("TIME: selected first time capability:", tostring(cap_id))
			monitor_capability(conn, cap_id)
			return
		else
			log.warn("TIME: capability meta message missing capability id token")
		end
	end
end

return M
