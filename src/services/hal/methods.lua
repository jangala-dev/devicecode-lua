-- services/hal/methods.lua
--
-- HAL method registry and lane routing.

local util = require 'services.hal.util'

local M = {}

function M.registry()
	return {
		-- Generic/state methods.
		read_state              = { kind = 'rpc' },
		write_state             = { kind = 'rpc' },
		dump                    = { kind = 'rpc' },
		open_serial_stream      = { kind = 'rpc' },

		-- Runtime sensing.
		list_links              = { kind = 'sense' },
		probe_links             = { kind = 'sense' },
		read_link_counters      = { kind = 'sense' },

		-- Structural apply.
		apply_net               = { kind = 'apply', domain = 'net' },
		apply_wifi              = { kind = 'apply', domain = 'wifi' },

		-- Runtime live apply.
		apply_link_shaping_live = { kind = 'live', domain = 'link_shaping_live' },
		apply_multipath_live    = { kind = 'live', domain = 'multipath_live' },
		persist_multipath_state = { kind = 'live', domain = 'multipath_persist' },
	}
end

function M.bind_endpoints(conn, methods, topic_fn)
	local endpoints = {}
	for method in pairs(methods) do
		endpoints[method] = conn:bind(topic_fn(method), { queue_len = 16 })
	end
	return endpoints
end

function M.enqueue_job(methods, method, queues, job)
	local meta = methods[method]
	if not meta then
		return false, 'unknown method'
	end

	if meta.kind == 'apply' then
		return util.try_enqueue(queues.apply_tx, job)
	elseif meta.kind == 'live' then
		return util.try_enqueue(queues.live_tx, job)
	elseif meta.kind == 'sense' then
		return util.try_enqueue(queues.sense_tx, job)
	else
		return util.try_enqueue(queues.rpc_tx, job)
	end
end

return M
