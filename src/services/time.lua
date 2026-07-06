-- services/time.lua
--
-- Time service:
--  - discovers the first HAL time capability via {'cap','time','+','meta','source'}
--  - consumes retained state + sync/unsync events from that capability
--  - publishes retained {'state','time','synced'} for system-wide time trust state
--  - nudges fibers alarm wall-clock handling when sync transitions occur

local fibers = require "fibers"
local op = require "fibers.op"
local alarm = require "fibers.alarm"
local time_utils = require "fibers.utils.time"

local base = require "devicecode.service_base"
local cap_sdk = require "services.hal.sdk.cap"

local perform = fibers.perform

local M = {}

---@param payload any
---@return boolean? synced
local function synced_from_state_payload(payload)
	if type(payload) ~= 'table' then return nil end
	if type(payload.synced) ~= 'boolean' then return nil end
	return payload.synced
end

---@param state table
---@param conn Connection
---@param svc ServiceBase
---@param is_synced boolean
---@param payload table?
---@return nil
local function apply_sync_state(state, conn, svc, is_synced, payload)
	if state.current_synced ~= is_synced then
		local what = is_synced and 'time_synced' or 'time_unsynced'
		svc:obs_log(is_synced and 'info' or 'warn', {
			what = what,
			summary = is_synced and 'time synchronised' or 'time synchronisation lost',
			from = state.current_synced,
			to   = is_synced,
		})
		conn:retain({ 'state', 'time', 'synced' }, is_synced)
		svc:obs_event(is_synced and 'synced' or 'unsynced', payload or {})
		state.current_synced = is_synced
	end

	-- New fibers core has set_time_source/time_changed instead of
	-- install_alarm_handler/clock_synced/clock_desynced.
	if is_synced then
		if not state.time_source_installed then
			svc:obs_log('debug', 'installing alarm time source from realtime clock')
			local ok, err = pcall(alarm.set_time_source, time_utils.realtime)
			if ok then
				state.time_source_installed = true
				svc:obs_log('debug', 'alarm time source installed')
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
---@param cap_ref CapabilityReference
---@return nil
local function monitor_capability(conn, svc, cap_ref)
	svc:obs_log('debug', { what = 'capability_monitor_start', cap_id = tostring(cap_ref.id) })
	local sub_state    = cap_ref:get_state_sub('synced')
	local sub_synced   = cap_ref:get_event_sub('synced')
	local sub_unsynced = cap_ref:get_event_sub('unsynced')

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
			svc:obs_log('debug', 'received initial retained sync state')
			local is_synced = synced_from_state_payload(msg.payload)
			if is_synced ~= nil then
				apply_sync_state(state, conn, svc, is_synced, msg.payload)
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
			apply_sync_state(state, conn, svc, true, msg.payload)
		elseif which == 'unsynced' then
			apply_sync_state(state, conn, svc, false, msg.payload)
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
	local heartbeat_s    = (type(opts.heartbeat_s)    == 'number') and opts.heartbeat_s    or 30.0
	local wait_timeout_s = (type(opts.wait_timeout_s) == 'number') and opts.wait_timeout_s or nil

	svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
	svc:obs_log('debug', 'service start() entered')
	svc:announce({})
	svc:starting()
	svc:spawn_heartbeat(heartbeat_s, 'tick')

	fibers.current_scope():finally(function()
		local _, primary = fibers.current_scope():status()
		svc:lifecycle('stopped', { ready = false, reason = tostring(primary or 'scope_exit') })
		svc:obs_log('debug', 'service stopped')
	end)

	svc:running()

	local cap_listener = cap_sdk.new_cap_listener(conn, 'time', '+')
	svc:obs_log('debug', { what = 'waiting_for_time_capability', timeout = wait_timeout_s })

	local cap_ref, cap_err = cap_listener:wait_for_cap({ timeout = wait_timeout_s })
	cap_listener:close()

	if not cap_ref then
		svc:obs_log('warn', { what = 'capability_discovery_failed', err = tostring(cap_err) })
		return
	end

	svc:obs_log('debug', { what = 'capability_selected', cap_id = tostring(cap_ref.id) })
	monitor_capability(conn, svc, cap_ref)
end

return M
