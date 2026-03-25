-- services/fabric/transfer.lua
--
-- Placeholder for bulk transfer / firmware update support.
--
-- Planned responsibilities:
--   * begin / ready / need / commit / done / abort
--   * chunking
--   * stop-and-wait
--   * progress publication under state/fabric/transfer/<id>

local M = {}

function M.not_implemented()
	return nil, 'fabric transfer not yet implemented'
end

return M
