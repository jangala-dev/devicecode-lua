-- services/device/dependencies.lua
-- Pure helpers for explicit component-action capability dependencies.

local M = {}

local function non_empty(v) return type(v) == 'string' and v ~= '' end

function M.action_dependency_key(component_id, action)
	return 'action:' .. tostring(component_id) .. ':' .. tostring(action)
end

local function copy_dependency(dep)
	if type(dep) ~= 'table' then return nil end
	local out = {}
	for k, v in pairs(dep) do out[k] = v end
	return out
end

function M.action_dependency_spec(component_id, action, action_spec)
	local dep = copy_dependency(type(action_spec) == 'table' and action_spec.dependency or nil)
	if dep == nil then return nil end
	if not non_empty(dep.class) then return nil, 'action dependency requires class' end
	if (dep.raw_kind == 'host' or dep.raw_kind == 'member') and not non_empty(dep.source) then
		return nil, 'raw action dependency requires source'
	end
	dep.key = dep.key or M.action_dependency_key(component_id, action)
	dep.id = dep.id or 'main'
	dep.required = dep.required ~= false
	dep.component = component_id
	dep.action = action
	return dep, nil
end

function M.catalogue_dependencies(catalogue)
	local specs, map = {}, {}
	for component_id, component in pairs((catalogue and catalogue.components) or {}) do
		for action, action_spec in pairs((component and component.actions) or {}) do
			local spec, err = M.action_dependency_spec(component_id, action, action_spec)
			if err ~= nil then return nil, nil, err end
			if spec ~= nil then
				specs[#specs + 1] = spec
				map[component_id] = map[component_id] or {}
				map[component_id][action] = spec.key
			end
		end
	end
	return specs, map, nil
end

return M
