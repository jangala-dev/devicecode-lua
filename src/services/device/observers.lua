local fibers = require 'fibers'
local status_watch = require 'services.device.providers.status_watch'

local M = {}

local PROVIDERS = {
    status_watch = status_watch,
}

local function provider_for(rec)
    local name = (type(rec) == 'table' and type(rec.provider) == 'string' and rec.provider ~= '') and rec.provider or 'status_watch'
    return PROVIDERS[name], name
end

local function emit(tx, ev)
    tx:send(ev)
end

local function provider_context(conn, name, rec, tx)
    return {
        conn = conn,
        component = name,
        rec = rec,
        tx = tx,
        emit = function(ev)
            emit(tx, ev)
        end,
    }
end

local function run_provider(ctx, provider)
    return provider.run(ctx)
end

function M.spawn_component(scope, conn, name, rec, tx)
    local provider, provider_name = provider_for(rec)
    if not provider or type(provider.run) ~= 'function' then
        return nil, 'unknown_provider:' .. tostring(provider_name)
    end

    local child, err = scope:child()
    if not child then return nil, err end

    local ok, spawn_err = child:spawn(function()
        local st, _rep, primary = fibers.run_scope(function()
            return run_provider(provider_context(conn, name, rec, tx), provider)
        end)

        if st == 'failed' then
            emit(tx, { tag = 'source_down', component = name, reason = tostring(primary or 'provider_failed') })
            error(primary or 'provider_failed', 0)
        elseif st == 'cancelled' then
            emit(tx, { tag = 'source_down', component = name, reason = tostring(primary or 'cancelled') })
        end
    end)
    if not ok then return nil, spawn_err end
    return child, nil
end

return M
