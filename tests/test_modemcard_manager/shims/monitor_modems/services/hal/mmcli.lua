local sleep = require "fibers.sleep"
local file = require "fibers.stream.file"
local simu_commands = require "SimuCommands"

-- Goes through a set of modem monitor connection/disconnection messages
-- with time delays to simulate cards being added and removed
local function monitor_modems()
    local cmd, _ = simu_commands.new('./test_modemcard_manager/shims/monitor_modems/services/hal/modemcard_states.json')
    return cmd
end

local function monitor_state(device)
    return simu_commands.new('./test_modemcard_manager/shims/monitor_modems/services/hal/modem_states.json')
end

-- Preset modem card info in the format of an mmcli -m <addr> request
local function information(ctx, device)
    return {
        combined_output = function ()
            sleep.sleep(0.05)
            local cardfile, err = file.open(
            "test_modemcard_manager/shims/monitor_modems/services/hal/modemcard_info.json", "r")
            if err then return nil end
            local carddata = cardfile:read_all_chars()
            return carddata
        end
    }
end

local function location_information()
    return {
        combined_output = function()
            sleep.sleep(0.05)
            return ""
        end
    }
end
return {
    monitor_modems = monitor_modems,
    monitor_state = monitor_state,
    information = information,
    location_information = location_information
}
