local json = require 'dkjson'
local request = require "http.request"
local log = require 'log'

local HTTPConnection = {}
HTTPConnection.__index = HTTPConnection

function HTTPConnection.new_HTTPConnection(config)
    return setmetatable({config = config}, HTTPConnection)
end

function HTTPConnection:sendMsg(msg)
    local url = self.config.url.."/"..msg.topic
    print("URL: ", url)
    
    local request_body = json.encode({msg.payload})
    local req = request.new_from_uri(url)
    req.headers:upsert(":method", "POST")
    req.headers:upsert("authorization", "Thing " .. self.config.mainflux_key)
    req.headers:upsert("content-type", "application/senml+json")
    req:set_body(request_body)
    req.headers:delete("expect")
    local response_headers, _ = req:go(10)

    if response_headers == nil or response_headers:get(":status") ~= "202" then
        log.info("TELEMETRY_FAIL")
        if response_headers ~= nil then
            for k, v in response_headers:each() do
                log.info("HEADERS_RESPONSE", k, v)
            end
        end
    else
        log.info("HTTP Connection, sent telemetry: "..json.encode(msg))
    end
end

return HTTPConnection