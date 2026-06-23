-- services/update/lifecycle_metrics.lua
--
-- Small publisher helper for component update lifecycle metrics. The Update
-- service derives lifecycle records from Device component facts, then calls
-- emit() with the phase it wants to publish.

local M = {}

M.METRIC_NAME = 'component_update_lifecycle'

-- Metric payload shape consumed by services.metrics:
-- {
--   value = 'started' | 'completed' | 'failed' | 'cancelled',
--   namespace = { '<component>', 'lifecycle', '<job_id>', '<phase>' },
--   job_id = '<original job id>', component = '<component id>', ...
-- }
-- The namespace is later used as a metrics topic suffix, so each segment must
-- avoid separators and whitespace.

---Return a string safe to use as one metric namespace segment.
---This is a topic/namespace normaliser, not a security boundary: it preserves
---letters, digits, '_' and '-', replaces every other run with '_', trims edge
---underscores, and falls back to 'unknown' if nothing usable remains.
---@param value any Original component or job identifier.
---@return string token Namespace-safe token.
local function safe_token(value)
	local s = tostring(value or '')
	s = s:gsub('[^%w%-_]', '_')
	s = s:gsub('_+', '_')
	s = s:gsub('^_+', ''):gsub('_+$', '')
	if s == '' then return 'unknown' end
	return s
end

---@param record table|nil Lifecycle record built from Device component facts.
---@return string|nil component Component id when present and non-empty.
local function component_of(record)
	local component = type(record) == 'table' and record.component or nil
	if type(component) ~= 'string' or component == '' then return nil end
	return component
end

---Build the metric payload expected by services.metrics.
---@param record table Lifecycle record with job_id/component/state/error fields.
---@param phase string Lifecycle phase to publish.
---@param extra table|nil Additional local-observability fields.
---@return table|nil payload Metric payload, or nil on invalid input.
---@return string|nil err Error code when payload is nil.
local function payload(record, phase, extra)
	local component = component_of(record)
	if not component then return nil, 'component_required' end
	if type(phase) ~= 'string' or phase == '' then return nil, 'phase_required' end

	local out = {
		value = phase,
		namespace = { safe_token(component), 'lifecycle', safe_token(record.job_id), phase },
		job_id = record.job_id,
		component = component,
		state = record.state,
		error = record.error,
	}
	for k, v in pairs(extra or {}) do
		out[k] = v
	end
	return out, nil
end

---@param conn table|nil Bus connection fallback, used when no service_base object exists.
---@param svc table|nil service_base-like object with obs_metric().
---@param p table Metric payload from payload().
---@return boolean|nil ok True when published.
---@return string|nil err Error code when no sink is available.
local function publish(conn, svc, p)
	if svc and type(svc.obs_metric) == 'function' then
		svc:obs_metric(M.METRIC_NAME, p)
		return true, nil
	end

	if conn and type(conn.retain) == 'function' then
		conn:retain({ 'obs', 'v1', 'update', 'metric', M.METRIC_NAME }, p)
		return true, nil
	end

	return nil, 'metric_sink_unavailable'
end

---@param value any
---@return string
function M.safe_token(value)
	return safe_token(value)
end

---@param conn table|nil
---@param svc table|nil
---@param record table Lifecycle record derived from a Device component fact.
---@param phase string
---@param extra table|nil
---@return boolean|nil ok
---@return string|nil err
function M.emit(conn, svc, record, phase, extra)
	local p, err = payload(record, phase, extra)
	if not p then return nil, err end
	return publish(conn, svc, p)
end

return M
