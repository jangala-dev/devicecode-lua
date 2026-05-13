-- services/device/publisher.lua
--
-- Immediate local-bus publication mechanics. Policy remains in the coordinator.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local projection  = require 'services.device.projection'

local M = {}

local function now_value(opts)
	if opts and type(opts.now) == 'function' then return opts.now() end
	local ok, fibers = pcall(require, 'fibers')
	if ok and fibers and type(fibers.now) == 'function' then return fibers.now() end
	return os.time()
end

local function checked(ok, err)
	if ok ~= true then return nil, err end
	return true, nil
end

function M.retain_now(conn, topic, payload, opts)
	return bus_cleanup.retain(conn, topic, payload, opts)
end

function M.unretain_now(conn, topic, opts)
	return bus_cleanup.unretain(conn, topic, opts)
end

function M.publish_now(conn, topic, payload, opts)
	return bus_cleanup.publish(conn, topic, payload, opts)
end

function M.publish_component_now(conn, snapshot, component_id, opts)
	local rec = snapshot and snapshot.components and snapshot.components[component_id] or nil
	if not rec then return true, nil end

	local ts = now_value(opts)
	local payloads = projection.component_payloads(component_id, rec, ts)

	local ok, err = checked(bus_cleanup.retain(conn, projection.component_topic(component_id), payloads.component))
	if not ok then return nil, err end
	ok, err = checked(bus_cleanup.retain(conn, projection.component_software_topic(component_id), payloads.software))
	if not ok then return nil, err end
	ok, err = checked(bus_cleanup.retain(conn, projection.component_update_topic(component_id), payloads.update))
	if not ok then return nil, err end
	ok, err = checked(bus_cleanup.retain(conn, projection.component_cap_meta_topic(component_id), payloads.cap_meta))
	if not ok then return nil, err end
	ok, err = checked(bus_cleanup.retain(conn, projection.component_cap_status_topic(component_id), payloads.cap_status))
	if not ok then return nil, err end

	if opts == nil or opts.emit_event ~= false then
		ok, err = checked(bus_cleanup.publish(
			conn,
			projection.component_cap_event_topic(component_id, 'state-changed'),
			projection.state_changed_event(component_id, rec, ts)
		))
		if not ok then return nil, err end
	end

	return true, nil
end

function M.unpublish_component_now(conn, component_id)
	local topics = {
		projection.component_topic(component_id),
		projection.component_software_topic(component_id),
		projection.component_update_topic(component_id),
		projection.component_cap_meta_topic(component_id),
		projection.component_cap_status_topic(component_id),
	}
	for i = 1, #topics do
		local ok, err = bus_cleanup.unretain(conn, topics[i])
		if ok ~= true then return nil, err end
	end
	return true, nil
end

function M.publish_summary_now(conn, snapshot, opts)
	local ts = now_value(opts)
	local ok, err = bus_cleanup.retain(conn, projection.summary_topic(), projection.summary_payload(snapshot, ts))
	if ok ~= true then return nil, err end
	return bus_cleanup.retain(conn, projection.identity_topic(), projection.identity_payload(snapshot, ts))
end

function M.publish_dirty_now(conn, snapshot, dirty, opts)
	dirty = dirty or {}
	for component_id in pairs(dirty.components or {}) do
		local ok, err = M.publish_component_now(conn, snapshot, component_id, opts)
		if ok ~= true then return nil, err end
	end

	if dirty.summary then
		local ok, err = M.publish_summary_now(conn, snapshot, opts)
		if ok ~= true then return nil, err end
	end
	return true, nil
end

function M.bind_now(conn, topic, opts)
	return bus_cleanup.bind(conn, topic, opts)
end

function M.unbind_now(conn, ep)
	return bus_cleanup.unbind(conn, ep)
end

return M
