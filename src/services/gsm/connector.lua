local fiber = require "fibers.fiber"
local channel = require "fibers.channel"
local exec = require "fibers.exec"
local context = require "fibers.context"
local utils = require "services.gsm.utils"
local json = require "dkjson"
local cache = require "cache"
local log = require "log"
local wraperr = require "wraperr"
local gpio = require "gpio"

local base, err = gpio.initialize_gpio()
if err then error("couldn't determine GPIO base") end
log.trace("GPIO base: ", base)

local connector = {}
connector.__index = connector

local function new(config)
    local self = setmetatable({}, connector)
    self.inputs = config.inputs
    self.outputs = config.outputs
    return self
end

-- this function will be spawned as a fiber, its role is to detect SIM insertions and removals
function connector:sim_detector(ctx)
    -- for now let's hardcode this

end

function connector:start_manager()
    -- this sets up the main control loop of the manager
end

return {
    new = new
}

--[[

-- Example usage
local connector_config = {
    inputs = {
        {sim = nil, type = "removable", detect = {method = "gpio", gpio_num = 5, gpio_state = "low"}},
        {sim = nil, type = "removable", detect = {method = "gpio", gpio_num = 6, gpio_state = "low"}},
        {sim = nil, type = "removable", detect = {method = "gpio", gpio_num = 13, gpio_state = "low"}},
        {sim = nil, type = "removable", detect = {method = "gpio", gpio_num = 19, gpio_state = "low"}},
        {sim = nil, type = "esim"},
        {sim = nil, type = "esim"}
    },
    outputs = {
        {
            modem = nil,
            modem_name = "primary",
            control_gpios = {18, 23, 24},
            input_mapping = {
                {"high", "low", "low"},
                {"high", "high", "low"},
                {"low", "low", "low"},
                {"low", "high", "low"},
                {"high", "high", "high"},
                {"high", "low", "high"}
            }
        },
        {
            modem = nil,
            modem_name = "secondary",
            control_gpios = {8, 7, 1},
            input_mapping = {
                {"high", "low", "low"},
                {"high", "high", "low"},
                {"low", "low", "low"},
                {"low", "high", "low"},
                {"high", "high", "high"},
                {"high", "low", "high"}
            }
        }
    }
}

]]
