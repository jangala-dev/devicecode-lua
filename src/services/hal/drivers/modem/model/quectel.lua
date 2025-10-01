local context = require "fibers.context"
local mmcli = require "services.hal.drivers.modem.mmcli"

local CMD_TIMEOUT = 3

-- driver/model/quectel.lua
local funcs = {
    {
        name = 'func1',
        conditionals = {
            function(modem)
                return modem.model == 'eg25'
            end,
            function(modem)
                return modem.model == 'em06'
            end
        },
        func = function(modem)
            print("Special function for EG25 and EM06")
        end
    },
    -- This is a special case for the RM520N, it has a initial bearer which will always cause a
    -- multiple PDN failure unless set to the APN we want to use OR set to empty.
    {
        name = 'connect',
        conditionals = {
            function(modem)
                return modem.model == 'rm520n'
            end
        },
        func = function(modem, connection_string)
            local clear_initial_bearer_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
            local cmd_clear = mmcli.three_gpp_set_initial_eps_bearer_settings(
                clear_initial_bearer_ctx,
                modem.address,
                "apn="
            )
            local out_clear, err_clear = cmd_clear:combined_output()
            if err_clear then
                return out_clear, err_clear
            end
            local connect_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
            local cmd = mmcli.connect(connect_ctx, modem.address, connection_string)
            local out, err = cmd:combined_output()
            return out, err
        end
    }
    -- Other functions
}

return function(modem)
    for _, f in ipairs(funcs) do
        for _, cond in ipairs(f.conditionals) do
            if cond(modem) then
                modem[f.name] = f.func
                break
            end
        end
    end
    return true
end
