-- services/metrics/http.lua
--
-- HTTP publisher for the metrics service.
--
-- Starts a dedicated fiber that drains a bounded channel of HTTP payloads and
-- sends them to the Mainflux cloud endpoint with exponential-backoff retry on
-- network failure.
--
-- Uses the HTTP capability service (services.http.sdk) so outbound requests
-- are handled via fiber-native Ops and do not block the cqueues event loop.
--
-- Public API:
--   start_http_publisher(http_ref, log_fn?) -> channel
--     Must be called from inside a running fiber scope.  Returns the send
--     channel (capacity QUEUE_SIZE).  The caller enqueues payloads with a
--     non-blocking put; if the channel is full the payload is dropped and an
--     error is logged.
--     http_ref: an http SDK ref obtained via http_sdk.new_ref(conn, id)
--     log_fn(level, payload) is an optional logger; defaults to log.debug/info.

local fibers       = require 'fibers'
local op           = require 'fibers.op'
local sleep        = require 'fibers.sleep'
local channel      = require 'fibers.channel'
local blob_source  = require 'devicecode.blob_source'

local QUEUE_SIZE   = 10
local HTTP_TIMEOUT = 60

--- Send a single HTTP payload to the cloud via the HTTP capability service,
--- retrying with exponential backoff on failure.  Returns only when the send
--- succeeds or the enclosing scope is cancelled.
---
---@param http_ref table  HTTP SDK ref (services.http.sdk Ref)
---@param data table      { uri: string, auth: string, body: string }
---@param log_fn fun(level: string, payload: any)
local function send_http(http_ref, data, log_fn)
	local uri            = data.uri
	local body           = data.body
	local auth           = data.auth

	local sleep_duration = 1
	local reply

	while not reply do
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

		if which == 'timeout' or not result then
			local err_msg = which == 'timeout' and 'timeout' or tostring(err)
			log_fn('debug', { what = 'http_retry', retry_in_s = sleep_duration, err = err_msg })
			sleep.sleep(sleep_duration)
			sleep_duration = math.min(sleep_duration * 2, 60)
		else
			reply = result
		end
	end

	local status = reply.result and reply.result.status
	if status ~= '202' then
		local parts = {}
		for k, v in pairs(reply.result and reply.result.headers or {}) do
			table.insert(parts, string.format('\t%s: %s', k, v))
		end
		log_fn('warn', {
			what    = 'http_publish_failed',
			status  = tostring(status),
			headers = table.concat(parts, '\n'),
		})
	else
		log_fn('info', { what = 'http_publish_ok', status = status })
	end
end

--- Start the HTTP publisher fiber in the current scope.
--- Returns the send channel.  Payloads must be enqueued with a non-blocking
--- select (see http_publish in metrics.lua); if the channel is full the
--- payload should be dropped by the caller.
---
---@param http_ref table                            HTTP SDK ref
---@param log_fn?  fun(level: string, payload: any) optional logger
---@return table channel
local function start_http_publisher(http_ref, log_fn)
	log_fn = log_fn or function() end

	local send_ch = channel.new(QUEUE_SIZE)

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
					send_http(http_ref, payload, log_fn)
				end
			end
		end)
	end)

	return send_ch
end

return {
	start_http_publisher = start_http_publisher,
}
