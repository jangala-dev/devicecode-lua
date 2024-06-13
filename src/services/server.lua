local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local channel = require 'fibers.channel'
local op = require 'fibers.op'
local json = require 'dkjson'
local log = require 'log'
local mimetypes = require '../ui/mimetypes'

-- http
local http_headers = require "http.headers"
local http_server = require "http.server"
local http_util = require "http.util"
local http_ws = require "http.websocket"
local server_service = {}
local myserver = nil

-- Server handling start
local function read_file(path)
    local file = io.open(path, "rb") -- r read mode and b binary mode
    if not file then return nil end
    local content = file:read "*a" -- *a or *all reads the whole file
    file:close()
    return content
end

local function is_static_asset(path)
    local static_file_extensions = {
		".js", ".css", ".png", ".jpg", ".jpeg", ".svg", ".ico", ".json", ".tff", ".eot", ".woff", "woff"
	}
    for _, extension in ipairs(static_file_extensions) do
        if path:sub(-#extension) == extension then
            return true
        end
    end
    return false
end

local function serve_spa(req_path)
    local base_path = "./ui/client/dist"

    -- If it's a known static asset, serve the file directly.
    if is_static_asset(req_path) then
        return base_path .. req_path
    else
        -- Otherwise, it's probably an HTML page and we should serve the index.html of SPA.
        return base_path .. "/index.html"
    end
end

local function reply(self, stream) -- luacheck: ignore 212
	-- Read in headers
	local req_headers = assert(stream:get_headers())
	local req_method = req_headers:get ":method"
	local req_path = req_headers:get ":path"

	-- Log request to stdout
	assert(io.stdout:write(string.format('[%s] "%s %s HTTP/%g"  "%s" "%s"\n',
		os.date("%d/%b/%Y:%H:%M:%S %z"),
		req_method or "",
		req_headers:get(":path") or "",
		stream.connection.version,
		req_headers:get("referer") or "-",
		req_headers:get("user-agent") or "-"
	)))

	-- Build response headers
	local res_headers = http_headers.new()

	if req_method ~= "GET" and req_method ~= "HEAD" and req_method ~= "PUT" then
		res_headers:upsert(":status", "405")
		assert(stream:write_headers(res_headers, true))
		return
	end

	if string.sub(req_path,1,string.len(self.api_prefix)) == self.api_prefix then
		log.info("/api call")
	elseif string.sub(req_path,1,string.len(self.ws_prefix)) == self.ws_prefix then
		log.info("/ws call")
		-- Suspected WebSocket upgrade request
		if req_headers:get("upgrade"):lower() == "websocket" then
			-- Try to create a new WebSocket server from the stream and headers
			local ws, err = http_ws.new_from_stream(stream, req_headers)
			if not ws then
				log.error("Failed to upgrade to WebSocket:", err)
				return
			end

			-- Perform WebSocket handshake here
			local ok, err = ws:accept()
			if not ok then
				log.error("WebSocket handshake failed:", err)
				return
			end

			log.info("WebSocket connection established within a fiber.")

			-- Spawn a new fiber to handle the WebSocket communication
			fiber.spawn(function()
				-- WebSocket communication loop
				while true do
					local message, err = ws:receive()
					if not message then
						-- handle error or closed WebSocket connection
						ws:close()
						break
					end
					-- Echo the message back to the client (or handle it differently)
					ws:send("Pong")
				end

				log.info("WebSocket connection closed within a fiber.")
			end)
		end
	elseif req_path == "/sse/event-stats" then
		log.info("/sse/event-stats call")
		res_headers:append(":status", "200")
		res_headers:append("content-type", "text/event-stream")
		-- Send headers to client; end the stream immediately if this was a HEAD request
		assert(stream:write_headers(res_headers, req_method == "HEAD"))
		if req_method ~= "HEAD" then
			local sub = server_service.bus_connection:subscribe("t.#") -- using multi-level wildcard
			-- Start a loop that sends the current time to the client each second

			while true do
				local msg, _ = sub:next_msg()
				local payload, _, _ = json.decode(msg.payload)
				msg.payload = payload

				local resp = "data: " .. json.encode(msg) .. "\n\n"
				local write_succesful = stream:write_chunk(resp, false)
				if not write_succesful then
					break
				end
			end
		end
	elseif req_path then
		log.info("html call", req_path)
		local path = serve_spa(req_path)
		local mimetype = mimetypes.guess(path)
		res_headers:append(":status", "200")

		if mimetype then
			res_headers:append("content-type", mimetype)
		end

		assert(stream:write_headers(res_headers, req_method == "HEAD"))
		if req_method ~= "HEAD" then
			local file = read_file(path)

			if file then
				assert(stream:write_chunk(file, true))
			end
		else
			res_headers:append(":status", "404")
			assert(stream:write_headers(res_headers, true))
		end
	end
end

local function error_reply(self, context, op, err)
	local msg = op .. " on " .. tostring(context) .. " failed"
	if err then
		msg = msg .. ": " .. tostring(err)
	end
	assert(io.stderr:write(msg, "\n"))
end

function server_service:init_server_config()
	if myserver ~= nil then
		return
	end

	myserver = assert(http_server.listen {
		host = "0.0.0.0";
		port = 80;
		onstream = reply;
		onerror = error_reply;
	})

	myserver.api_prefix = "/api";
	myserver.ws_prefix = "/ws";

	log.info("overriding server's 'add_stream' method")
	function myserver:add_stream(stream)
		fiber.spawn(function()
			fiber.yield()
			local ok, err = http_util.yieldable_pcall(self.onstream, self, stream)
			stream:shutdown()
			if not ok then
				self:onerror()(self, stream, "onstream", err)
			end
		end)
	end
end

-- Server handling end
function server_service:handle_server()
	log.trace("Starting Server Service")

	fiber.spawn(function()
        local quit = false
        while quit == false do
			op.choice(
                self.server_stop_ch:get_op():wrap(function()
					log.trace("Closing server")
					myserver:close()
					log.trace("Server closed")
					myserver = nil
					quit = true
				end)
            ):perform_alt(function()
				assert(myserver:step(0.1))
				sleep.sleep(1)
			end)
        end
    end)
end

function server_service:init_server(bus_connection)
	-- set bus connection
	self.bus_connection = bus_connection
	-- create necessary channels
	self.server_stop_ch = channel.new()

	self:init_server_config()
end

function server_service:start(rootctx, bus_connection)
	if myserver ~= nil then
		log.warn("Can't start server as already exists")
		return
	end

	-- start services
	self:init_server(bus_connection)
	self:handle_server()
end

function server_service:stop()
	if myserver == nil then
		log.warn("server deosn't exist")
		return
	end

	log.warn("stopping server")
    self.server_stop_ch:put(true)
end

-- return {
-- 	start = function(rootctx, bus_connection)
-- 		server_service:start(rootctx, bus_connection)
-- 	end,
-- 	stop = function()
-- 		server_service:stop()
-- 	end
-- }
return server_service