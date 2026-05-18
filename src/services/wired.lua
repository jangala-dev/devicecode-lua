-- services/wired.lua
--
-- Public entry point for the Wired service.

local fibers = require 'fibers'
local service = require 'services.wired.service'

local M = {}

function M.start(conn, opts)
	opts = opts or {}
	opts.conn = conn
	return service.run(fibers.current_scope(), opts)
end

return M
