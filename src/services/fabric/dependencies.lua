-- services/fabric/dependencies.lua
-- Pure helpers for deriving Fabric capability dependencies from compiled config.

local M = {}

local function non_empty(v)
	return type(v) == 'string' and v ~= ''
end

function M.transport_dependency_key(link_id)
	return 'transport:' .. tostring(link_id)
end

local function bypassed_by_override(override)
	return type(override) == 'table' and (
		override.open_transport_op ~= nil
		or override.transport_session ~= nil
		or override.local_rx ~= nil
	)
end

function M.transport_dependency_for_link(link, override)
	if type(link) ~= 'table' then return nil end
	if bypassed_by_override(override) then return nil end
	if link.open_transport_op ~= nil or link.transport_session ~= nil or link.local_rx ~= nil then return nil end
	local t = link.transport
	if type(t) ~= 'table' then return nil end
	if not (non_empty(t.source) and non_empty(t.class) and non_empty(t.id)) then return nil end
	return {
		key = M.transport_dependency_key(link.link_id or link.id),
		raw_kind = 'host',
		source = t.source,
		class = t.class,
		id = t.id,
		required = true,
		link_id = link.link_id or link.id,
	}
end

function M.transport_dependencies(compiled, overrides)
	local out = {}
	for i, link in ipairs((compiled and compiled.links) or {}) do
		local link_id = link.link_id or link.id
		local override = type(overrides) == 'table' and (overrides[link_id] or overrides[i]) or nil
		local spec = M.transport_dependency_for_link(link, override)
		if spec ~= nil then out[#out + 1] = spec end
	end
	return out
end

return M
