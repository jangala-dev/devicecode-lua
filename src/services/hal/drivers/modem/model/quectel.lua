-- driver/model/quectel.lua
local funcs = {
    {
        name = 'func1',
        conditionals = {
            function (modem)
                return modem.model == 'eg25'
            end,
            function (modem)
                return modem.model == 'em06'
            end
        },
        func = function(modem)
            print("Special function for EG25 and EM06")
        end
    },
    -- Other functions
}

return function(modem)
    for _, f in ipairs(funcs) do
        for _, cond in ipairs(f.conditionals) do
            if cond(modem) then modem[f.name] = f.func break end
        end
    end
    return true
end