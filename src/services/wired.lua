-- services/wired.lua
--
-- Public entry point for the Wired service.

local fibers = require 'fibers'
local service_base = require 'devicecode.service_base'
local service = require 'services.wired.service'

local M = {}

function M.start(conn, opts)
	opts = opts or {}
	opts.conn = conn
	local svc = service_base.new(conn, { name = opts.name or 'wired', env = opts.env, meta = opts.meta, announce = opts.announce })
	svc:starting({ ready = false })
	opts.svc = svc
	local scope = fibers.current_scope()
	scope:finally(function (_, status, primary)
		if status == 'failed' then svc:failed(primary or 'wired_failed') else svc:stopped({ reason = primary or status or 'wired_stopped' }) end
	end)
	svc:running({ ready = false })
	return service.run(scope, opts)
end

return M
