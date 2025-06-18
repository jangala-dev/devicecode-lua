local sleep = require "fibers.sleep"

-- For testing a modem not existing we only need
-- the information function, this will signify a fail
-- during modem_driver init function
local function information(ctx, device)
    return {
        combined_output = function()
            sleep.sleep(0.05)
            return nil, "no device of address 0"
        end
    }
end

return {
    information = information
}
