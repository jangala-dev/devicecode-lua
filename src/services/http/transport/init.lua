-- services/http/transport/init.lua

return {
	cqueues_driver = require 'services.http.transport.cqueues_driver',
	lua_http       = require 'services.http.transport.lua_http',
	websocket      = require 'services.http.transport.websocket',
	request_body   = require 'services.http.transport.request_body',
	terminate      = require 'services.http.transport.terminate',
}
