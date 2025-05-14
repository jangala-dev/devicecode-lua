local fiber = require "fibers.fiber"
local channel = require 'fibers.channel'
local sleep = require "fibers.sleep"
local pollio = require "fibers.pollio"
local file = require "fibers.stream.file"
local http_server = require "http.server"
local http_headers = require "http.headers"
local http_util = require "http.util"
local websocket = require "http.websocket"
local cjson = require "cjson.safe"

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
-- Runtime state
local ws_clients = {} -- list of active WebSocket clients
local sse_clients = {} -- list of active WebSocket clients

local function serve_static(stream, path)
    -- Very simple static file server
    print("path:", path)
    local handle, err = file.open(path, "rb")
    if not handle or err then
        -- 404
        local res_headers = http_headers.new()
        res_headers:append(":status", "404")
        res_headers:append("content-type", "text/plain")
        assert(stream:write_headers(res_headers, true))
        return
    end

    local res_headers = http_headers.new()
    res_headers:append(":status", "200")
    res_headers:append("content-type", "text/html") -- assume HTML for now; later infer from extension
    assert(stream:write_headers(res_headers, false))

    while true do
        local chunk = handle:read(4096)
        if not chunk then break end
        assert(stream:write_chunk(chunk, false))
    end

    handle:close()
    assert(stream:write_chunk("", true))
end

local function handle_websocket(ctx, ws)
    table.insert(ws_clients, ws)

    while not ctx:err() do
        local message, errmsg, errcode = ws:receive()
        print(message, errmsg, errcode)
        if message == nil then
            print("breaking!")
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

local function handle_sse(ctx, stream)
    local stats_channel = channel.new()
    table.insert(sse_clients, stats_channel)

    while not ctx:err() do
        local msg = stats_channel:get()

        if msg then
            local sse_msg = "data: " .. msg .. "\n\n"
            local ok, err = pcall(function()
                stream:write_chunk(sse_msg, false)
            end)
            if not ok then
                print("Client disconnected or write error:", err)
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
        print("api call")
    elseif req_type == ws_prefix then
        -- Attempt WebSocket upgrade directly
        local ws, err = websocket.new_from_stream(stream, req_headers)
        if ws then
            print("websocket upgrade request")
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
            handle_sse(ctx, stream)
        elseif req_path == sse_logs then
            print("sse logs")
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

    local file_path = "www/ui" .. (req_path == "/" and "/index.html" or req_path)
    serve_static(stream, file_path)
end

local function publish_to_ws_clients(payload)
    local msg = cjson.encode(payload)
    for _, ws in ipairs(ws_clients) do
        local ok, err = pcall(function()
            ws:send(msg)
        end)
        if not ok then
            print("Failed to send to websocket client:", err)
        end
    end
end

local function publish_to_sse_clients(payload)
    local msg = cjson.encode(payload)

    for _, sse_channel in ipairs(sse_clients) do
        local ok, err = pcall(function()
            sse_channel:put(msg)
        end)

        if not ok then
            print("Failed to send to SSE client:", err)
        end
    end
end

local function bus_listener(ctx, connection)
    local sub = connection:subscribe({ "metrics", "#" })
    while not ctx:err() do
        local msg, err = sub:next_msg()
        if msg then
            publish_to_ws_clients({
                topic = msg.topic,
                payload = msg.payload
            })
            publish_to_sse_clients({
                topic = msg.topic,
                payload = msg.payload
            })
        elseif err then
            print("Bus subscription error:", err)
        end
    end
    sub:unsubscribe()
end

function ui_service:start(ctx, connection)
    print("Starting UI service")

    pollio.install_poll_io_handler()

    local server = assert(http_server.listen {
        host = "0.0.0.0",
        port = 8081,
        onstream = onstream,
        onerror = function(_, context, operation, err)
            print(operation, "on", context, "failed:", err)
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
