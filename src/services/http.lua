-- services/http.lua
-- Public entry point for the HTTP capability service.

local service = require 'services.http.service'

return {
	start = service.start,
	service = service,
	sdk = require 'services.http.sdk',
	headers = require 'services.http.headers',
	config = require 'services.http.config',
	policy = require 'services.http.policy',
	client = require 'services.http.client',
	listener = require 'services.http.listener',
	context = require 'services.http.context',
	websocket = require 'services.http.websocket',
	body = require 'services.http.body',
	topics = require 'services.http.topics',
}
