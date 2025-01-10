local exec = require 'fibers.exec'
local sleep = require "fibers.sleep"
local context = require 'fibers.context'
local wraperr = require "wraperr"
local qmicli = require "services.hal.qmicli"
local log = require "log"

local CMD_TIMEOUT = 2

-- driver/mode/qmi.lua
return function(modem)
    modem.example_1 = function()
        print("Running QMI example 1...")
    end
    modem.example_2 = function()
        print("Running QMI example 2...")
    end

    modem.is_sim_inserted = function()
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_get_card_status(new_ctx, modem)
        local out, err = cmd:combined_output()
        if err then return wraperr.new(err) end

        local status = out:match("Card state:%s'(.-)\n"):gsub("'", "")
        if status:find("present") then return true, nil end
        return false, nil -- just a different OO form
    end

    modem.set_func_min = function()
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_sim_power_off(new_ctx, modem)
        local out, err = cmd:combined_output()
        if err then return wraperr.new(err) end

        return nil
    end

    modem.set_func_max = function()
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_sim_power_on(new_ctx, modem)
        local out, err = cmd:combined_output()
        if err then return wraperr.new(err) end

        return nil
    end

    modem.wait_for_sim = function()
        while not modem.ctx:err() and not modem.is_sim_inserted() do
            modem.set_func_min()
            modem.set_func_max()
            sleep.sleep(0.1)
        end
    end
    -- Add other QMI-specific methods
    return true
end
