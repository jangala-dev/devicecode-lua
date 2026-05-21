-- services/wired/dependencies.lua
-- Pure helpers for configured wired-provider capability dependencies.

local M = {}

function M.provider_dependency_key(provider_id)
	return 'provider:' .. tostring(provider_id)
end

function M.provider_dependencies(intent)
	local out, seen = {}, {}
	for _, surface in pairs((intent and intent.surfaces) or {}) do
		local provider_id = surface and surface.provider and surface.provider.capability_id or nil
		if type(provider_id) == 'string' and provider_id ~= '' and not seen[provider_id] then
			seen[provider_id] = true
			out[#out + 1] = {
				key = M.provider_dependency_key(provider_id),
				class = 'wired-provider',
				id = provider_id,
				required = false,
				provider_id = provider_id,
			}
		end
	end
	return out
end

return M
