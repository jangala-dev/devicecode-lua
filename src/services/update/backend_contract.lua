-- services/update/backend_contract.lua
--
-- Minimal, explicit backend contract for update component backends.
-- Backends own component-specific transport/staging/reconcile policy; the
-- update service shell owns orchestration and persisted job state.

local M = {}

M.required_methods = {
	'prepare',
	'stage',
	'commit',
	'evaluate',
}

function M.validate(name, backend)
	if type(backend) ~= 'table' then
		return nil, 'backend_not_table:' .. tostring(name)
	end
	for _, method in ipairs(M.required_methods) do
		if type(backend[method]) ~= 'function' then
			return nil, 'backend_missing_' .. method .. ':' .. tostring(name)
		end
	end
	if backend.observe_specs ~= nil and type(backend.observe_specs) ~= 'function' then
		return nil, 'backend_bad_observe_specs:' .. tostring(name)
	end
	return backend, nil
end

function M.observe_specs(name, backend, cfg)
	if not backend or type(backend.observe_specs) ~= 'function' then
		return {}, nil
	end
	local specs = backend:observe_specs(cfg)
	if specs == nil then return {}, nil end
	if type(specs) ~= 'table' then
		return nil, 'backend_observe_specs_not_table:' .. tostring(name)
	end
	return specs, nil
end

return M
