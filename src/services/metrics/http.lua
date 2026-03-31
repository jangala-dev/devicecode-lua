-- services/metrics/http.lua
--
-- HTTP publisher for the metrics service.
--
-- Starts a dedicated fiber that drains a bounded channel of HTTP payloads and
-- sends them to the Mainflux cloud endpoint with exponential-backoff retry on
-- network failure.
--
-- Public API:
--   start_http_publisher(log_fn?) -> channel
--     Must be called from inside a running fiber scope.  Returns the send
--     channel (capacity QUEUE_SIZE).  The caller enqueues payloads with a
--     non-blocking put; if the channel is full the payload is dropped and an
--     error is logged.
--     log_fn(level, payload) is an optional logger; defaults to log.debug/info.

local fibers     = require 'fibers'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local channel    = require 'fibers.channel'
local request    = require 'http.request'

local QUEUE_SIZE = 10

--- Send a single HTTP payload to the cloud, retrying with exponential backoff
--- on network failure.  Returns only when the send succeeds or the enclosing
--- scope is cancelled.
---
---@param data table  { uri: string, auth: string, body: string }
---@param log_fn fun(level: string, payload: any)
local function send_http(data, log_fn)
    local uri            = data.uri
    local body           = data.body
    local auth           = data.auth

    local sleep_duration = 1
    local response_headers

    while not response_headers do
        local req = request.new_from_uri(uri)
        req.headers:upsert(':method', 'POST')
        req.headers:upsert('authorization', auth)
        req.headers:upsert('content-type', 'application/senml+json')
        req.headers:delete('expect')
        req:set_body(body)

        local headers = req:go(10)
        response_headers = headers

        if not response_headers then
            log_fn('debug', { what = 'http_retry', retry_in_s = sleep_duration })
            sleep.sleep(sleep_duration)
            sleep_duration = math.min(sleep_duration * 2, 60)
        end
    end

    local status = response_headers:get(':status')
    if status ~= '202' then
        local parts = {}
        for k, v in response_headers:each() do
            table.insert(parts, string.format('\t%s: %s', k, v))
        end
        log_fn('warn', { what = 'http_publish_failed', status = status,
            headers = table.concat(parts, '\n') })
    else
        log_fn('info', { what = 'http_publish_ok', status = status })
    end
end

--- Start the HTTP publisher fiber in the current scope.
--- Returns the send channel.  Payloads must be enqueued with a non-blocking
--- select (see _http_publish in metrics.lua); if the channel is full the
--- payload should be dropped by the caller.
---
---@param log_fn? fun(level: string, payload: any)  optional logger
---@return table channel
local function start_http_publisher(log_fn)
    log_fn = log_fn or function() end

    local send_ch = channel.new(QUEUE_SIZE)

    local scope = fibers.current_scope()
    scope:spawn(function()
        while true do
            local which, payload = fibers.perform(op.named_choice({
                msg = send_ch:get_op(),
            }))
            if which == 'msg' and payload ~= nil then
                send_http(payload, log_fn)
            end
        end
    end)

    return send_ch
end

return {
    start_http_publisher = start_http_publisher,
}
