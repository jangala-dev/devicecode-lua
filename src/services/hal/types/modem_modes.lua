-- Canonical cellular mode values shared by HAL and GSM policy.
local tablex = require 'shared.table'
local M = {}
local generations = { ['2g'] = true, ['3g'] = true, ['4g'] = true, ['5g'] = true }

---@class ModemModeCombination
---@field preferred string
---@field allowed string[]

---@return ModemModeCombination? combination
---@return string error
function M.normalize(preferred, allowed)
    if preferred ~= 'none' and not generations[preferred] then
        return nil, 'preferred must be none, 2g, 3g, 4g or 5g'
    end
    if not tablex.is_array(allowed) or #allowed == 0 then
        return nil, 'allowed must be a nonempty generation list'
    end
    local count = 0
    for _ in pairs(allowed) do count = count + 1 end
    if count ~= #allowed then return nil, 'allowed must be a dense generation list' end
    local values, seen = {}, {}
    for _, generation in ipairs(allowed) do
        if not generations[generation] then
            return nil, 'allowed contains an invalid generation'
        end
        if not seen[generation] then
            values[#values + 1] = generation
            seen[generation] = true
        end
    end
    table.sort(values)
    return { preferred = preferred, allowed = values }, ''
end

function M.includes(combination, generation)
    for _, allowed in ipairs(combination.allowed) do
        if generation == allowed then return true end
    end
    return false
end

function M.key(combination)
    return combination.preferred .. ':' .. table.concat(combination.allowed, '|')
end

function M.equal(a, b)
    return a ~= nil and b ~= nil and M.key(a) == M.key(b)
end

return M
