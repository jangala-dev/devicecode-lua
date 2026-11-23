-- services/metrics/http.lua
--
-- HTTP publisher for the metrics service.
--
-- Starts a dedicated fiber that drains a bounded channel of HTTP payloads and
-- sends them to the Mainflux cloud endpoint with exponential-backoff retry on
-- network failure or temporary HTTP failure.
--
-- Uses the HTTP capability service (services.http.sdk) so outbound requests
-- are handled via fiber-native Ops and do not block the cqueues event loop.
--
-- Public API:
--   start_http_publisher(http_ref, log_fn?, timestamp?) -> sender
--     Must be called from inside a running fiber scope.  Returns the send
--     interface (capacity QUEUE_SIZE). A timestamp callback enables delivery
--     diagnostics and should_report(uri, auth) for idle reports. The caller
--     logs queue-full drops.
--     http_ref: an http SDK ref obtained via http_sdk.new_ref(conn, id)
--     log_fn(level, payload) is an optional logger; defaults to log.debug/info.

local fibers       = require 'fibers'
local op           = require 'fibers.op'
local sleep        = require 'fibers.sleep'
local channel      = require 'fibers.channel'
local blob_source  = require 'devicecode.blob_source'
local time         = require 'fibers.utils.time'
local retry        = require 'services.metrics.http_retry'
local runtime      = require 'fibers.runtime'
local json         = require 'cjson.safe'

local DIAGNOSTIC_PREFIX = require('services.metrics.types').HTTP_DIAGNOSTIC_PREFIX

local QUEUE_SIZE   = 10
local HTTP_TIMEOUT = 60

-- Snapshot values are copied before sending so an acknowledgement cannot
-- hide changes that occurred while a request was in flight.
local function new_diagnostics(timestamp)
	local started = runtime.now()
	local values = { dropped_queue_full = 0, retries = 0, queue_depth = 0 }
	local last, last_uri, last_auth
	local diag = { values = values }

	function diag.changed(uri, auth)
		if not last or uri ~= last_uri or auth ~= last_auth then return true end
		for name, value in pairs(values) do
			if last[name] ~= value then return true end
		end
		return false
	end

	function diag.snapshot(data)
		if not diag.changed(data.uri, data.auth) then return end
		values.started_at = values.started_at or timestamp(started)
		local snapshot, records = {}, {}
		local at = timestamp(runtime.now())
		for name, value in pairs(values) do
			snapshot[name] = value
			records[#records + 1] = { n = DIAGNOSTIC_PREFIX .. name, v = value, t = at }
		end
		return snapshot, assert(json.encode(records))
	end

	function diag.accept(data, snapshot)
		last, last_uri, last_auth = snapshot, data.uri, data.auth
	end

	return diag
end

--- Send a single HTTP payload to the cloud via the HTTP capability service,
--- retrying with exponential backoff on failure.  Returns only when the send
--- succeeds, the retry allowance is exhausted, or the enclosing scope is cancelled.
---
---@param http_ref table  HTTP SDK ref (services.http.sdk Ref)
--- With data.one_shot any failure is reported through on_result, not retried.
---
---@alias MetricsHttpPayload { uri: string, auth: string, body: string,
---  one_shot?: boolean, on_result?: fun(accepted: boolean), diagnostics_only?: boolean }
---@param data MetricsHttpPayload
---@param log_fn fun(level: string, payload: any)
local function send_http(http_ref, data, log_fn, diag)
	local uri            = data.uri
	local auth           = data.auth

	local state

	while true do
		local body, snapshot = data.body, nil
		if diag then
			if state and not data.diagnostics_only then diag.values.retries = diag.values.retries + 1 end
			local records
			snapshot, records = diag.snapshot(data)
			if snapshot then
				-- The service supplies a compact JSON array of SenML records.
				local prefix = body == '[]' and '[' or body:sub(1, -2) .. ','
				body = prefix .. records:sub(2)
			elseif data.diagnostics_only then
				return
			end
		end
		log_fn('trace', { what = 'http_publish_attempt', status = 'started' })
		local which, result, err = fibers.perform(op.named_choice({
			response = http_ref:exchange_op({
				method      = 'POST',
				uri         = uri,
				headers     = {
					authorization    = auth,
					['content-type'] = 'application/senml+json',
				},
				body_source = blob_source.from_string(body),
			}),
			timeout  = sleep.sleep_op(HTTP_TIMEOUT),
		}))
		log_fn('trace', { what = 'http_publish_attempt', status = which })

		local response = type(result) == 'table' and type(result.result) == 'table' and result.result or {}
		local status = response.status
		local headers = type(response.headers) == 'table' and response.headers or {}
		local outcome, err_msg
		if which == 'timeout' then
			outcome, err_msg = 'timeout', 'timeout'
		elseif not result then
			outcome, err_msg = 'network_failure', tostring(err)
		else
			outcome = retry.classify(status)
		end

		state = retry.next(state, outcome, data.one_shot)
		local max_retries = state.max_retries == math.huge and 'unlimited' or state.max_retries
		if state.success then
			if snapshot then diag.accept(data, snapshot) end
			log_fn('trace', { what = 'http_publish_ok', status = status })
			if data.on_result then data.on_result(true) end
			return
		end
		if retry.is_exhausted(state) then
			if diag and not data.diagnostics_only and not err_msg then
				local suffix = outcome == 'invalid_response' and outcome or tostring(tonumber(status))
				local name = 'rejected.' .. suffix
				diag.values[name] = (diag.values[name] or 0) + 1
			end
			local parts = {}
			for k, v in pairs(headers) do parts[#parts + 1] = string.format('\t%s: %s', k, tostring(v)) end
			log_fn('warn', {
				what = data.one_shot and err_msg and 'http_one_shot_failed' or 'http_publish_failed',
				status = tostring(status), outcome = state.outcome, retry = state.retry,
				max_retries = max_retries, err = err_msg, headers = table.concat(parts, '\n'),
			})
			if data.on_result then data.on_result(false) end
			return
		end

		local delay = retry.delay(state, headers, time.realtime())
		log_fn('debug', {
			what = 'http_retry', retry_in_s = delay, status = status, err = err_msg,
			outcome = state.outcome, retry = state.retry, max_retries = max_retries,
		})
		sleep.sleep(delay)
	end
end

--- Start the HTTP publisher fiber in the current scope.
--- With diagnostics enabled the sender's put_op returns true on overflow
--- and nil on admission. The plain channel uses the caller's non-blocking select.
---
---@param http_ref table                            HTTP SDK ref
---@param log_fn?  fun(level: string, payload: any) optional logger
---@param timestamp? fun(monotonic_s: number): number enable diagnostics with the service clock
---@return table sender
local function start_http_publisher(http_ref, log_fn, timestamp)
	log_fn = log_fn or function() end

	local send_ch = channel.new(QUEUE_SIZE)
	local diag = timestamp and new_diagnostics(timestamp)
	local active, diagnostic_pending = false, false
	local sender = send_ch
	if diag then
		sender = {}
		function sender:put_op(data)
			return send_ch:put_op(data):wrap(function()
				if data.diagnostics_only then
					diagnostic_pending = true
				else
					diag.values.queue_depth = diag.values.queue_depth + 1
				end
			end):or_else(function()
				if not data.diagnostics_only then
					diag.values.dropped_queue_full = diag.values.dropped_queue_full + 1
				end
				return true
			end)
		end
		function sender:should_report(uri, auth)
			return not active and not diagnostic_pending and diag.values.queue_depth == 0 and diag.changed(uri, auth)
		end
	end

	fibers.spawn(function()
		fibers.run_scope(function(s)
			s:finally(function(aborted, _, sc_err)
				if aborted then
					log_fn('fatal', 'HTTP publisher fiber: ' .. tostring(sc_err))
				else
					log_fn('trace', 'HTTP publisher fiber: exiting')
				end
			end)

			while true do
				local which, payload = fibers.perform(op.named_choice({
					msg = send_ch:get_op(),
				}))
				if which == 'msg' and payload ~= nil then
					if diag and not payload.diagnostics_only then
						diag.values.queue_depth = diag.values.queue_depth - 1
					end
					active = true
					send_http(http_ref, payload, log_fn, diag)
					active = false
					if payload.diagnostics_only then diagnostic_pending = false end
				end
			end
		end)
	end)

	return sender
end

return {
	start_http_publisher = start_http_publisher,
}
