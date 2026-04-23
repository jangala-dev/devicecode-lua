-- services/device/topics.lua
--
-- Canonical topic constructors used by the device service and its providers.
-- Keep topic spelling here rather than scattering string arrays across the
-- service shell, projections, tests, and future component providers.

local M = {}

local function copy_array(t)
	local out = {}
	if type(t) ~= 'table' then return out end
	for i = 1, #t do out[i] = t[i] end
	return out
end

local function append(base, ...)
	local out = copy_array(base)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if type(v) == 'table' then
			for j = 1, #v do out[#out + 1] = v[j] end
		else
			out[#out + 1] = v
		end
	end
	return out
end

function M.copy(topic)
	return copy_array(topic)
end

function M.self()
	return { 'state', 'device', 'self' }
end

function M.components()
	return { 'state', 'device', 'components' }
end

function M.component(name)
	return { 'state', 'device', 'component', name }
end

function M.component_software(name)
	return append(M.component(name), 'software')
end

function M.component_update(name)
	return append(M.component(name), 'update')
end

function M.component_event(name, event_name)
	return { 'event', 'device', 'component', name, event_name }
end

function M.member_state(member, ...)
	return append({ 'state', 'member', member }, ...)
end

function M.member_event(member, ...)
	return append({ 'event', 'member', member }, ...)
end

function M.cap_updater_state(component, fact)
	return { 'cap', 'updater', component, 'state', fact }
end

function M.cap_updater_rpc(component, method)
	return { 'cap', 'updater', component, 'rpc', method }
end

return M
