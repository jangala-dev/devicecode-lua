local status_watch = require 'services.device.providers.status_watch'

local M = {}

local PROVIDERS = {
    status_watch = status_watch,
}

local function provider_for(rec)
    local name = (type(rec) == 'table' and type(rec.provider) == 'string' and rec.provider ~= '') and rec.provider or 'status_watch'
    return PROVIDERS[name], name
end

function M.spawn_component(scope, conn, name, rec, tx)
    local provider, provider_name = provider_for(rec)
    if not provider or type(provider.spawn) ~= 'function' then
        return nil, 'unknown_provider:' .. tostring(provider_name)
    end
    return provider.spawn(scope, conn, name, rec, tx)
end

return M
