local modes = require 'services.hal.types.modem_modes'
local M = {}

-- Only apply a complete preferred/allowed pair advertised by the modem.
function M.select(request, supported)
    if type(request) ~= 'table' then return nil, 'cellular_modes must be a table' end
    local wanted, err = modes.normalize(request.preferred, request.allowed)
    if not wanted then return nil, err end
    for _, candidate in ipairs(supported) do
        if modes.equal(wanted, candidate) then return candidate, '' end
    end
    return nil, 'no supported combination matches the requested preferred and allowed modes'
end

return M
