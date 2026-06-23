-- services/http/cap_surface.lua
-- Bus-facing HTTP capability surface.  The surface owns endpoint bindings and
-- retained capability metadata/status; service.lua supplies the handlers.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local topics = require 'services.http.topics'

local M = {}

local OFFERINGS = {
	'status',
	'listen',
	'open-exchange',
	'exchange',
	'connect-ws',
}

local function offerings_map()
	local out = {}
	for _, name in ipairs(OFFERINGS) do out[name] = true end
	return out
end

function M.retain_static(conn, id, status, stats)
	conn:retain(topics.meta(id), {
		kind = 'cap.http',
		class = 'http',
		id = id or 'main',
		owner = 'http',
		methods = offerings_map(),
		offerings = offerings_map(),
		local_handles = { listen = true, ['open-exchange'] = true, ['connect-ws'] = true },
		control_plane_only = true,
		compat = { response_parsers = { strict = true, ['legacy-http1-close'] = true } },
		state = { stats = topics.state(id, 'stats') },
		observability = { status = topics.obs_metric(id, 'status') },
	})
	conn:retain(topics.status(id), status or { state = 'starting', available = false })
	conn:retain(topics.state(id, 'stats'), stats or {})
	conn:retain(topics.obs_metric(id, 'status'), stats or {})
end

function M.unretain_static(conn, id)
	conn:unretain(topics.meta(id))
	conn:unretain(topics.status(id))
	conn:unretain(topics.state(id, 'stats'))
	conn:unretain(topics.obs_metric(id, 'status'))
	conn:unretain(topics.obs_metric(id, 'stats'))
end

function M.bind(conn, id, handlers, opts)
	opts = opts or {}
	local endpoints = {}
	for _, verb in ipairs(OFFERINGS) do
		local ep, err = bus_cleanup.bind(conn, topics.rpc(id, verb), opts.endpoint_opts)
		if not ep then
			for _, prev in pairs(endpoints) do bus_cleanup.unbind(conn, prev) end
			return nil, err
		end
		endpoints[verb] = ep
	end
	return endpoints
end

function M.unbind(conn, endpoints)
	for _, ep in pairs(endpoints or {}) do bus_cleanup.unbind(conn, ep) end
	return true
end

M.OFFERINGS = OFFERINGS
return M
