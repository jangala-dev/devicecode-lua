local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'

local geo_service = {}
geo_service.__index = geo_service

function geo_service:start(bus_connection)
    self.bus_connection = bus_connection
end

return geo_service