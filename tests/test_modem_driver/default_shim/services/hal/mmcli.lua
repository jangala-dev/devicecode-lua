local sleep = require "fibers.sleep"
local file = require "fibers.stream.file"
local json = require "dkjson"
local simu_commands = require "test_utils.SimuCommands"

local function monitor_modems()
end

local function inhibit(device)
    return {
        start = function()
            sleep.sleep(0.05)
            return nil
        end,
        kill = function()
            sleep.sleep(0.05)
        end
    }
end

local function connect(device)
    return {
        run = function()
            sleep.sleep(0.05)
            return "connect"
        end
    }
end

local function disconnect(device)
    return {
        run = function()
            sleep.sleep(0.05)
            return "disconnect"
        end
    }
end

local function reset(device)
    return {
        run = function()
            sleep.sleep(0.05)
            return "reset"
        end
    }
end

local function enable(device)
    return {
        run = function()
            sleep.sleep(0.05)
            return "enable"
        end
    }
end

local function disable(device)
    return {
        run = function()
            sleep.sleep(0.05)
            return "disable"
        end
    }
end

local function monitor_state(device)
    return simu_commands.new('./test_modem_driver/default_shim/services/hal/modem_states.json')
end

local function information(ctx, device)
    return {
        combined_output = function()
            sleep.sleep(0.05)
            local cardfile, err = file.open("./test_modem_driver/default_shim/services/hal/modemcard_info.json", "r")
            if err then return nil end
            local carddata = cardfile:read_all_chars()
            return carddata
        end
    }
end

return {
    monitor_modems = monitor_modems,
    inhibit = inhibit,
    connect = connect,
    disconnect = disconnect,
    reset = reset,
    enable = enable,
    disable = disable,
    monitor_state = monitor_state,
    information = information
}
