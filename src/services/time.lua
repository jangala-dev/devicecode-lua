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

local base = require "devicecode.service_base"

local perform = fibers.perform

local M = {}

---@return table
local function t(...)
	return { ... }
end

---@param payload any
---@return boolean? synced
local function synced_from_state_payload(payload)
	if type(payload) ~= 'table' then return nil end
	if type(payload.synced) ~= 'boolean' then return nil end
	return payload.synced
end

---@param state table
---@param svc ServiceBase
---@param is_synced boolean
---@param payload table?
---@return nil
local function apply_sync_state(state, svc, is_synced, payload)
	if state.current_synced ~= is_synced then
		svc:obs_log('info', {
			what = 'sync_state_transition',
			from = tostring(state.current_synced),
			to   = tostring(is_synced),
		})
		svc:status(is_synced and 'synced' or 'unsynced')
		svc:obs_event(is_synced and 'synced' or 'unsynced', payload or {})
		state.current_synced = is_synced
	end

	-- New fibers core has set_time_source/time_changed instead of
	-- install_alarm_handler/clock_synced/clock_desynced.
	if is_synced then
		if not state.time_source_installed then
			svc:obs_log('info', 'installing alarm time source from realtime clock')
			local ok, err = pcall(alarm.set_time_source, time_utils.realtime)
			if ok then
				state.time_source_installed = true
				svc:obs_log('info', 'alarm time source installed')
			else
				svc:obs_log('warn', { what = 'alarm_time_source_failed', err = tostring(err) })
			end
		else
			alarm.time_changed()
		end
	end
end

---@param conn Connection
---@param svc ServiceBase
---@param cap_id CapabilityId
---@return nil
local function monitor_capability(conn, svc, cap_id)
	svc:obs_log('info', { what = 'capability_monitor_start', cap_id = tostring(cap_id) })
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
			svc:obs_log('info', 'received initial retained sync state')
			local is_synced = synced_from_state_payload(msg.payload)
			if is_synced ~= nil then
				apply_sync_state(state, svc, is_synced, msg.payload)
			else
				svc:obs_log('warn', { what = 'initial_state_invalid', reason = 'missing boolean synced field' })
			end
		else
			svc:obs_log('warn', { what = 'initial_state_read_failed', err = tostring(err) })
		end
		sub_state:unsubscribe()
	end

	while true do
		local which, msg, err = perform(op.named_choice({
			synced = sub_synced:recv_op(),
			unsynced = sub_unsynced:recv_op(),
		}))

		if not msg then
			svc:obs_log('warn', { what = 'capability_monitor_closed', err = tostring(err) })
			return
		end

		if which == 'synced' then
			apply_sync_state(state, svc, true, msg.payload)
		elseif which == 'unsynced' then
			apply_sync_state(state, svc, false, msg.payload)
		else
			svc:obs_log('warn', { what = 'unknown_event_source', source = tostring(which) })
		end
	end
end

---@param conn Connection
---@param opts table?
---@return nil
function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'time', env = opts.env })
	local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0

	svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
	svc:obs_log('info', 'service start() entered')
	svc:status('starting')
	svc:spawn_heartbeat(heartbeat_s, 'tick')

	fibers.current_scope():finally(function()
		local st, primary = fibers.current_scope():status()
		if st == 'failed' then
			svc:obs_log('error', { what = 'scope_failed', err = tostring(primary), status = st })
		end
		svc:status('stopped', { reason = tostring(primary or 'scope_exit') })
		svc:obs_log('info', 'service stopped')
	end)

	local sub_meta = conn:subscribe(t('cap', 'time', '+', 'meta', 'source'), {
		queue_len = 10,
		full = 'drop_oldest',
	})
	svc:obs_log('info', { what = 'subscribed', topic = 'cap/time/+/meta/source' })

	svc:status('running')

	while true do
		local msg, err = perform(sub_meta:recv_op())
		if not msg then
			sub_meta:unsubscribe()
			svc:obs_log('warn', { what = 'capability_discovery_closed', err = tostring(err) })
			return
		end

		local topic = msg.topic
		local cap_id = topic and topic[3]
		if cap_id ~= nil then
			sub_meta:unsubscribe()
			svc:obs_log('info', { what = 'capability_selected', cap_id = tostring(cap_id) })
			monitor_capability(conn, svc, cap_id)
			return
		else
			svc:obs_log('warn', { what = 'capability_meta_missing_id' })
		end
	end
end

return M
