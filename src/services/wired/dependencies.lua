-- services/wired/dependencies.lua
-- Wired does not derive capability dependencies from cfg/wired.  Physical
-- backing is resolved through Device assembly plus raw wired observations.

local M = {}

function M.observation_dependencies(_intent)
	return {}
end

return M
