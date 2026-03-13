-- services/metrics/http.lua
--
-- HTTP publisher for the metrics service.
--
-- Starts a dedicated fiber that drains a bounded channel of HTTP payloads and
-- sends them to the Mainflux cloud endpoint with exponential-backoff retry on
-- network failure.
--
-- Public API:
--   start_http_publisher() -> channel
--     Must be called from inside a running fiber scope.  Returns the send
--     channel (capacity QUEUE_SIZE).  The caller enqueues payloads with a
--     non-blocking put; if the channel is full the payload is dropped and an
--     error is logged.

local fibers     = require 'fibers'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local channel    = require 'fibers.channel'
local request    = require 'http.request'
local log        = require 'services.log'

local QUEUE_SIZE = 10

--- Send a single HTTP payload to the cloud, retrying with exponential backoff
--- on network failure.  Returns only when the send succeeds or the enclosing
--- scope is cancelled.
---
---@param data table  { uri: string, auth: string, body: string }
local function send_http(data)
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
            log.debug(string.format(
                'metrics/http: HTTP publish failed, retrying in %s seconds',
                sleep_duration))
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
        log.debug(string.format(
            'metrics/http: HTTP publish failed, response headers:\n%s',
            table.concat(parts, '\n')))
    else
        log.info('metrics/http: HTTP publish success, status: ' .. status)
    end
end

--- Start the HTTP publisher fiber in the current scope.
--- Returns the send channel.  Payloads must be enqueued with a non-blocking
--- select (see _http_publish in metrics.lua); if the channel is full the
--- payload should be dropped by the caller.
---
---@return table channel
local function start_http_publisher()
    local send_ch = channel.new(QUEUE_SIZE)

    local scope = fibers.current_scope()
    scope:spawn(function()
        while true do
            local which, payload = fibers.perform(op.named_choice({
                msg = send_ch:get_op(),
            }))
            if which == 'msg' and payload ~= nil then
                send_http(payload)
            end
        end
    end)

    return send_ch
end

return {
    start_http_publisher = start_http_publisher,
}
