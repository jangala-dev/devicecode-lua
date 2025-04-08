-- driver/mode/mbim.lua
return function(modem)
    modem.example_1 = function()
        print("Running MBIM example 1...")
    end
    modem.example_2 = function()
        print("Running MBIM example 2...")
    end
    -- Add other MBIM-specific methods
    return true
end
