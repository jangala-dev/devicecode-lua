-- Safe dynamic loader for Fabric protocol profiles.
--
-- Profile kinds map to modules below services.fabric.profiles. A restricted
-- identifier grammar keeps configuration from escaping that namespace.

local M = {}

M.DEFAULT_KIND = 'fabric_jsonl_v1'

local KIND_PATTERN = '^[a-z][a-z0-9_]*$'
local MODULE_PREFIX = 'services.fabric.profiles.'

local function validate_contract(kind, profile)
	if type(profile) ~= 'table' then
		return nil, 'fabric protocol profile must return a table: ' .. kind
	end
	if profile.kind ~= kind then
		return nil, 'fabric protocol profile kind mismatch: ' .. kind
	end
	if type(profile.compile) ~= 'function' then
		return nil, 'fabric protocol profile has no compile function: ' .. kind
	end
	if type(profile.run) ~= 'function' then
		return nil, 'fabric protocol profile has no run function: ' .. kind
	end
	if type(profile.capabilities) ~= 'table' then
		return nil, 'fabric protocol profile has no capabilities table: ' .. kind
	end
	if type(profile.link_sections) ~= 'table' then
		return nil, 'fabric protocol profile has no link_sections table: ' .. kind
	end
	return profile, nil
end

function M.load(kind)
	if type(kind) ~= 'string' or kind:match(KIND_PATTERN) == nil then
		return nil, 'protocol.kind must match ' .. KIND_PATTERN
	end
	local ok, profile = pcall(require, MODULE_PREFIX .. kind)
	if not ok then
		return nil, 'fabric protocol profile unavailable: ' .. kind .. ': ' .. tostring(profile)
	end
	return validate_contract(kind, profile)
end

return M
