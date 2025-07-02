local context = require "fibers.context"
local queue = require "fibers.queue"
local op = require "fibers.op"
local sleep = require "fibers.sleep"
local service = require "service"
local request = require 'http.request'
local log = require "log"

local function send_http(ctx, data)
    local uri = data.uri
    local body = data.body
    local auth = data.auth

    local response_headers
    local sleep_duration = 1
    while not response_headers do
        local req = request.new_from_uri(uri)
        req.headers:upsert(":method", "POST")
        req.headers:upsert("authorization", auth)
        req.headers:upsert("content-type", "application/senml+json")
        req:set_body(body)
        req.headers:delete("expect")
        local headers,  _ = req:go(10)
        response_headers = headers
        if not response_headers then
            sleep.sleep(sleep_duration)
            sleep_duration = math.min(sleep_duration * 2, 60) -- Exponential backoff, max 60 seconds
        end
    end

    if not response_headers then
        log.error(string.format(
            "%s - %s: HTTP publish failed, reason: %s",
            ctx:value('service_name'),
            ctx:value('fiber_name'),
            "No response headers"
        ))
        return
    elseif response_headers:get(":status") ~= "202" then
        local header_msgs = ""
        for k, v in pairs(response_headers:each()) do
            header_msgs = string.format("%s\n\t%s: %s", header_msgs, k, v)
        end

        log.debug(string.format(
            "%s - %s: HTTP publish failed, header responses: %s",
            ctx:value('service_name'),
            ctx:value('fiber_name'),
            header_msgs
        ))
    else
        log.info(string.format(
            "%s - %s: HTTP publish success, response: %s",
            ctx:value('service_name'),
            ctx:value('fiber_name'),
            response_headers:get(":status")
        ))
    end
end

local function start_http_publisher(ctx, conn)
    local http_ctx = context.with_cancel(ctx)
    local to_send_queue = queue.new(10)

    service.spawn_fiber("HTTP Publish", conn, ctx, function ()
        while not http_ctx:err() do
            op.choice(
                to_send_queue:get_op():wrap(function (data) send_http(http_ctx, data) end),
                http_ctx:done_op()
            ):perform()
        end
    end)

    return to_send_queue
end

return {
    start_http_publisher = start_http_publisher
}
