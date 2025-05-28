local fiber = require "fibers.fiber"
local channel = require 'fibers.channel'
local pollio = require "fibers.pollio"
local file = require "fibers.stream.file"
local log = require "services.log"
local http_server = require "http.server"
local http_headers = require "http.headers"
local http_util = require "http.util"
local websocket = require "http.websocket"
local cjson = require "cjson.safe"
local op = require "fibers.op"
require "services.ui.fibers_cqueues"

local ui_service = {
    name = 'ui'
}
ui_service.__index = ui_service

-- TODO move into server config
local api_prefix = "api"
local ws_prefix = "ws"
local sse_prefix = "sse"
local sse_stats = "/" .. sse_prefix .. "/stats"
local sse_logs = "/" .. sse_prefix .. "/logs"
local stats_stream = "stats"
local log_stream = "logs"
local logs_subscription = "logs"
local gsm_subscription = "gsm"
local system_subscription = "system"
local net_subscription = "net"
-- Runtime state
local ws_clients = {} -- list of active WebSocket clients
local sse_clients = {} -- list of active WebSocket clients
local stats_messages_cache = {}
local log_messages_cache = {}

local function get_static_mimetype(path)
    local ext_to_type = {
        [".js"]   = "application/javascript",
        [".css"]  = "text/css",
        [".png"]  = "image/png",
        [".jpg"]  = "image/jpeg",
        [".jpeg"] = "image/jpeg",
        [".svg"]  = "image/svg+xml",
        [".ico"]  = "image/x-icon",
        [".json"] = "application/json",
        [".tff"]  = "font/ttf",
        [".eot"]  = "application/vnd.ms-fontobject",
        [".woff"] = "font/woff",
        [".webmanifest"] = "application/manifest+json",
        [".webp"] = "image/webp",
    }

    for ext, mime in pairs(ext_to_type) do
        if path:sub(- #ext) == ext then
            return mime
        end
    end

    return nil
end

local function is_static_asset(path)
    return get_static_mimetype(path) ~= nil
end

local function get_spa_path(req_path)
    local base_path = "./www/ui/dist"

    -- If it's a known static asset, serve the file directly.
    if is_static_asset(req_path) then
        return base_path .. req_path
    else
        -- Otherwise, it's probably an HTML page and we should serve the index.html of SPA.
        return base_path .. "/index.html"
    end
end

local function handle_websocket(ctx, ws)
    table.insert(ws_clients, ws)

    while not ctx:err() do
        local message, errmsg, errcode = ws:receive()
        if message == nil then
            break
        end
        -- handle incoming messages if necessary
    end

    -- Cleanup
    for i, client in ipairs(ws_clients) do
        if client == ws then
            table.remove(ws_clients, i)
            break
        end
    end
end

local function handle_sse(ctx, stream, subscription)
    local stats_channel = channel.new()
    table.insert(sse_clients, stats_channel)

    -- Send latest cached messages to new SSE client
    local send_cached_message = function(cached_msg)
        local sse_msg = "data: " .. cjson.encode(cached_msg) .. "\n\n"
        local ok, err = pcall(function()
            stream:write_chunk(sse_msg, false)
        end)
        if not ok then
            log.warn("SSE: Failed to send cached message:", err)
            return false
        end
        return true
    end

    if subscription == stats_stream then
        for _, cached_msg in pairs(stats_messages_cache) do
            local ok = send_cached_message(cached_msg)
            if not ok then
                break
            end
        end
    elseif subscription == log_stream then
        for _, cached_msg in ipairs(log_messages_cache) do
            local ok = send_cached_message(cached_msg)
            if not ok then
                break
            end
        end
    end

    while not ctx:err() do
        local msg = stats_channel:get()

        if msg and msg.subscription == subscription then
            local sse_msg = "data: " .. cjson.encode(msg) .. "\n\n"
            local ok, err = pcall(function()
                stream:write_chunk(sse_msg, false)
            end)
            if not ok then
                log.warn("SSE: Client disconnected or write error:", err)
                break
            end
        end
    end

    -- Cleanup: remove the channel from sse_clients
    for i, ch in ipairs(sse_clients) do
        if ch == stats_channel then
            table.remove(sse_clients, i)
            break
        end
    end
end

local function onstream(self, stream)
    local req_headers = assert(stream:get_headers())
    local req_method = req_headers:get(":method") or "GET"
    local req_path = req_headers:get(":path") or "/"
    local req_type = req_path:match("^/([^/]+)")

    -- Invalid method
    if req_method ~= "GET" and req_method ~= "HEAD" and req_method ~= "PUT" then
        local res_headers = http_headers.new()
        res_headers:upsert(":status", "405")
        assert(stream:write_headers(res_headers, true))
        return
    end

    -- Dynamic request handling
    if req_type == api_prefix then
        log.info("API call")
    elseif req_type == ws_prefix then
        -- Attempt WebSocket upgrade directly
        local ws, err = websocket.new_from_stream(stream, req_headers)
        if ws then
            log.info("Websocket upgrade request")
            -- Successful WebSocket upgrade
            ws:accept()
            local ctx = { err = function() return false end }
            handle_websocket(ctx, ws)
            return
        end
    elseif req_type == sse_prefix then
        if req_path == sse_stats then
            local res_headers = http_headers.new()
            res_headers:append(":status", "200")
            res_headers:append("content-type", "text/event-stream")
            assert(stream:write_headers(res_headers, req_method == "HEAD"))

            local ctx = { err = function() return false end }
            -- Ideally there would be a handeful of retained messages to populate the initial state
            handle_sse(ctx, stream, stats_stream)
        elseif req_path == sse_logs then
            local res_headers = http_headers.new()
            res_headers:append(":status", "200")
            res_headers:append("content-type", "text/event-stream")
            assert(stream:write_headers(res_headers, req_method == "HEAD"))

            local ctx = { err = function() return false end }
            handle_sse(ctx, stream, log_stream)
        end
    end

    -- Normal HTTP static file serving
    if req_method ~= "GET" then
        local res_headers = http_headers.new()
        res_headers:append(":status", "405")
        res_headers:append("content-type", "text/plain")
        assert(stream:write_headers(res_headers, true))
        assert(stream:write_chunk("405 Method Not Allowed\n", true))
        return
    end

    local path = get_spa_path(req_path)
    local handle, err = file.open(path, "rb")
    local res_headers = http_headers.new()

    if not handle then
        log.warn("Failed to open file:", err)
        res_headers:append(":status", "404")
        assert(stream:write_headers(res_headers, true))
        return
    end

    res_headers:append(":status", "200")
    local mimetype = get_static_mimetype(path) or "text/html"
    res_headers:append("content-type", mimetype)
    assert(stream:write_headers(res_headers, req_method == "HEAD"))

    if req_method ~= "HEAD" then
        while true do
            local chunk = handle:read(4096)
            if not chunk then break end
            assert(stream:write_chunk(chunk, false))
        end
        assert(stream:write_chunk("", true)) -- EOF
    end

    handle:close()
end

local function publish_to_ws_clients(payload)
    local msg = cjson.encode(payload)
    for _, ws in ipairs(ws_clients) do
        local ok, err = pcall(function()
            ws:send(msg)
        end)
        if not ok then
            log.warn("Failed to send to websocket client:", err)
        end
    end
end

local function publish_to_sse_clients(payload)
    for _, sse_channel in ipairs(sse_clients) do
        local ok, err = pcall(function()
            sse_channel:put(payload)
        end)

        if not ok then
            log.warn("Failed to send to SSE client:", err)
        end
    end
end

local function bus_listener(ctx, connection)
    local sub_gsm = connection:subscribe({ gsm_subscription, "#" })
    local sub_system = connection:subscribe({ system_subscription, "#" })
    local sub_net = connection:subscribe({ net_subscription, "#" })
    local sub_logs = connection:subscribe({ logs_subscription, "#" })

    local publish_message = function(msg, subscription)

        if subscription == stats_stream then
            local topic_key = table.concat(msg.topic, ".")

            stats_messages_cache[topic_key] = {
                topic = msg.topic,
                payload = msg.payload,
                subscription = subscription
            }
        elseif subscription == log_stream then
            table.insert(log_messages_cache, {
                topic = msg.topic,
                payload = msg.payload,
                subscription = subscription
            })

            -- Keep only the last 200 log messages
            if #log_messages_cache > 200 then
                table.remove(log_messages_cache, 1)
            end
        end

        publish_to_ws_clients({
            topic = msg.topic,
            payload = msg.payload
        })
        publish_to_sse_clients({
            topic = msg.topic,
            payload = msg.payload,
            subscription = subscription
        })
    end

    while not ctx:err() do
        -- TODO unsure how to handle errors here
        op.choice(
            sub_gsm:next_msg_op():wrap(function(msg)
                publish_message(msg, stats_stream)
            end),
            sub_system:next_msg_op():wrap(function(msg)
                publish_message(msg, stats_stream)
            end),
            sub_net:next_msg_op():wrap(function(msg)
                publish_message(msg, stats_stream)
            end),
            sub_logs:next_msg_op():wrap(function(msg)
                publish_message(msg, log_stream)
            end)
        ):perform()
    end

    sub_logs:unsubscribe()
    sub_gsm:unsubscribe()
    sub_system:unsubscribe()
    sub_net:unsubscribe()
end

function ui_service:start(ctx, connection)
    log.trace("Starting UI service")

    pollio.install_poll_io_handler()

    local server = assert(http_server.listen {
        host = "0.0.0.0",
        port = 80,
        onstream = onstream,
        onerror = function(_, context, operation, err)
            log.warn(operation, "on", context, "failed:", err)
        end
    })

    function server:add_stream(stream)
        fiber.spawn(function()
            fiber.yield()
            local ok, err = http_util.yieldable_pcall(self.onstream, self, stream)
            stream:shutdown()
            if not ok then
                self:onerror()(self, stream, "onstream", err)
            end
        end)
    end

    fiber.spawn(function()
        assert(server:loop())
    end)

    fiber.spawn(function()
        bus_listener(ctx, connection)
    end)
end

return ui_service
