-- tests/unit/metrics/endpoint_prune_spec.lua
--
-- Per-endpoint processing state in the metrics service is dropped once an
-- endpoint has been idle for a day, so per-session endpoints do not pile up.

local runtime = require 'fibers.runtime'
local metrics = require 'services.metrics'
local processing = require 'services.metrics.processing'

local T = {}

local function session_msg(sid)
	return {
		topic = { 'obs', 'v1', 'wifi', 'metric', 'session_start' },
		payload = { value = 1700000000, namespace = { 'wifi', 'clients', 'u1', 'sessions', sid, 'session_start' } },
	}
end

function T.idle_endpoints_are_pruned_and_active_ones_kept()
	local t = metrics._test
	local State = t.State
	local pipeline = assert(processing.new_process_pipeline())
	State.pipelines_map = { session_start = { pipeline = pipeline, protocol = 'http' } }
	State.metric_states, State.endpoint_to_pipe, State.endpoint_seen, State.metric_values = {}, {}, {}, {}
	State.svc = { obs_log = function () end }

	t.handle_metric(session_msg('old'))
	t.handle_metric(session_msg('new'))
	local old_ep = 'wifi.clients.u1.sessions.old.session_start'
	local new_ep = 'wifi.clients.u1.sessions.new.session_start'
	assert(State.metric_states[old_ep] and State.metric_states[new_ep], 'both endpoints tracked')

	local tnow = runtime.now()
	State.endpoint_seen[old_ep] = tnow - 2 * 24 * 60 * 60
	t.prune_idle_endpoints(tnow)

	assert(State.metric_states[old_ep] == nil, 'idle endpoint state should be dropped')
	assert(State.endpoint_to_pipe[old_ep] == nil, 'idle endpoint pipe mapping should be dropped')
	assert(State.endpoint_seen[old_ep] == nil, 'idle endpoint timestamp should be dropped')
	assert(State.metric_states[new_ep] ~= nil, 'recent endpoint should be kept')
end

return T
