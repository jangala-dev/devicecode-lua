-- services/device/topics.lua
--
-- Pure topic construction helpers for the Device service.

local topic = require 'shared.topic'

local M = {}

function M.copy(t)
	return topic.copy(t)
end

function M.config()
	return { 'cfg', 'device' }
end

function M.identity()
	return { 'state', 'device', 'identity' }
end

function M.components()
	return { 'state', 'device', 'components' }
end

function M.assembly()
	return { 'state', 'device', 'assembly' }
end

function M.component(name)
	return { 'state', 'device', 'component', name }
end

function M.component_software(name)
	return topic.append(M.component(name), 'software')
end

function M.component_update(name)
	return topic.append(M.component(name), 'update')
end

function M.component_cap_meta(name)
	return { 'cap', 'component', name, 'meta' }
end

function M.component_cap_status(name)
	return { 'cap', 'component', name, 'status' }
end

function M.component_cap_event(name, event)
	return { 'cap', 'component', name, 'event', event }
end

function M.component_cap_rpc(name, method)
	return { 'cap', 'component', name, 'rpc', method }
end

function M.raw_member_state(member, ...)
	return topic.append({ 'raw', 'member', member, 'state' }, ...)
end

function M.raw_member_cap_event(member, class, id, ...)
	return topic.append({ 'raw', 'member', member, 'cap', class, id, 'event' }, ...)
end

function M.raw_member_cap_rpc(member, class, id, method)
	return { 'raw', 'member', member, 'cap', class, id, 'rpc', method }
end

function M.raw_host_cap_state(source, class, id, ...)
	return topic.append({ 'raw', 'host', source, 'cap', class, id, 'state' }, ...)
end

function M.raw_host_cap_rpc(source, class, id, method)
	return { 'raw', 'host', source, 'cap', class, id, 'rpc', method }
end

return M
