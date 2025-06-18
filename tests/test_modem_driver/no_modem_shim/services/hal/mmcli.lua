local sleep = require "fibers.sleep"
local file = require "fibers.stream.file"
local json = require "dkjson"
local simu_commands = require "test_utils.SimuCommands"

local function information(ctx, device)
    return {
        combined_output = function()
            sleep.sleep(0.05)
            return nil, "no modem found"
        end
    }
end

return {
    information = information
}
