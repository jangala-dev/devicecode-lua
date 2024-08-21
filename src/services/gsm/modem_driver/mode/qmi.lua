-- driver/mode/qmi.lua
return function(modem)
    modem.example_1 = function()
        print("Running QMI example 1...")
    end
    modem.example_2 = function()
        print("Running QMI example 2...")
    end
    -- Add other QMI-specific methods
    return true
end
