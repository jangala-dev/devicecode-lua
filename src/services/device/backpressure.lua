-- services/device/backpressure.lua
--
-- Explicit Device publication/backpressure policy.
--
-- This module is deliberately data-only.  Coordinators and workers import these
-- constants so queue/full-policy choices are visible in code rather than hidden
-- in ad hoc literals.

local M = {}

M.policy = {
	-- Completion events are safety/ownership relevant.  They must not be silently
	-- dropped: reporters use required immediate admission and fail the observing
	-- scope if this queue cannot accept a completion while healthy.
	completions = {
		queue_full = 'fail_observing_scope',
		full = 'reject_newest',
		default_len = 64,
	},

	-- Observations are semantic input to the Device model.  Observer reporters use
	-- required immediate admission, so failure to admit is observer/service failure
	-- rather than silent telemetry loss.
	observations = {
		queue_full = 'fail_observing_scope',
		full = 'reject_newest',
		default_len = 128,
	},

	-- Public action endpoint queues reject new requests when full.  The public bus
	-- endpoint reports this to the caller; Device does not block the coordinator to
	-- wait for endpoint capacity.
	action_endpoints = {
		queue_full = 'reject_request',
		full = 'reject_newest',
		default_len = 32,
	},

	-- Raw observer feeds are low-level input queues.  Repeated retained/fact/event
	-- updates can be coalesced by the observer/model; stale old raw items may be
	-- dropped in favour of newer state.
	observer_feeds = {
		queue_full = 'drop_oldest_raw',
		full = 'drop_oldest',
		default_len = 8,
	},

	-- Publication is dirty-state coalesced.  Repeated model changes mark the same
	-- component dirty and are flushed as retained/public state; publication failure
	-- fails the Device coordinator rather than being silently dropped.
	publication = {
		policy = 'coalesce_dirty_state',
		failure = 'fail_service',
	},

	-- Source-down/stale observations do not fail the service by themselves.  They
	-- update the model through availability policy and normally publish degraded or
	-- unavailable public state.
	availability = {
		source_down = 'mark_degraded_or_unavailable',
		observer_failure = 'record_and_mark_source_down',
	},
}

function M.snapshot()
	local out = {}
	for k, v in pairs(M.policy) do
		local copy = {}
		for kk, vv in pairs(v) do copy[kk] = vv end
		out[k] = copy
	end
	return out
end

return M
