-- services/wired/dependencies.lua
-- Wired no longer derives capability dependencies from cfg/wired.
-- Provider observations are resolved through Device assembly plus raw wired facts.

local M = {}

function M.provider_dependencies(_intent)
	return {}
end

return M
