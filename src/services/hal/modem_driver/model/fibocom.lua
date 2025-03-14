-- driver/model/fibocom.lua
local funcs = {
    {
        name = 'func1',
        models = {l860 = true, fm350 = true},
        func = function(modem)
            print("Special function for L860 and FM350")
        end
    },
    -- Other functions
}

return function(modem)
    for _, f in ipairs(funcs) do
        if f.models[modem:model()] then
            modem[f.name] = f.func
        end
    end
    return true
end