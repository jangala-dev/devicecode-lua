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
        if err then return nil, wraperr.new(err) end

        local status = out:match("Card state:%s'(.-)\n"):gsub("'", "")
        if status:find("present") then return true, nil end
        return false, nil
    end

    modem.set_func_min = function()
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_sim_power_off(new_ctx, modem.primary_port)
        local out, err = cmd:combined_output()
        if err then return wraperr.new(err) end

        return nil
    end

    modem.set_func_max = function()
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_sim_power_on(new_ctx, modem.primary_port)
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
    modem.monitor_slot_state = function()
        return qmicli.uim_monitor_slot_status(modem.primary_port)
    end

    modem.get_mcc_mnc = function()
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.nas_get_home_network(new_ctx, modem.primary_port)
        local out, err = cmd:combined_output()
        if err then return nil, nil, wraperr.new(err) end

        local mcc = out:match("MCC:%s+'(%d+)'")
        local mnc = out:match("MNC:%s+'(%d+)'")
        return mcc, mnc, nil
    end

    modem.gid1 = function()
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_read_transparent(new_ctx, modem.primary_port, '0x3F00,0x7FFF,0x6F3E')
        local out, err = cmd:combined_output()
        if err then return nil, wraperr.new(err) end

        local read_result = out:match("Read result:%s*(%S+)")

        return read_result, nil
    end
    -- Add other QMI-specific methods
    return true
end
