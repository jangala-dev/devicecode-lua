-- services/http.lua
-- Public entry point for the HTTP capability service.

local fibers = require 'fibers'
local service = require 'services.http.service'

local M = {
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

function M.start(conn, opts)
	local instance, err = service.start(conn, opts)
	if not instance then error(err or 'http service start failed', 0) end
	fibers.perform(fibers.never())
end

return M
