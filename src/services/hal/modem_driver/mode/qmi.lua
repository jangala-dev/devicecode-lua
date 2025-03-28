local exec = require 'fibers.exec'
local sleep = require "fibers.sleep"
local context = require 'fibers.context'
local wraperr = require "wraperr"
local qmicli = require "services.hal.qmicli"
local utils = require "services.hal.utils"
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

    modem.uim_get_gids = function()
        local gids = {}
        local key_map = {
            ["Card result"] = "card-result",
            SW1 = 'sw1',
            SW2 = 'sw2',
            ["Read result"] = "read-result"
        }
        local gid1_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local gid1_cmd = qmicli.uim_read_transparent(gid1_ctx, modem.primary_port, '0x3F00,0x7FFF,0x6F3E')
        local gid1_out, gid1_cmd_err = gid1_cmd:combined_output()
        if gid1_cmd_err then return gids, wraperr.new(gid1_cmd_err) end

        local gid1_out_parsed, gid1_parse_err = utils.parse_qmicli_output(gid1_out, key_map)
        if gid1_parse_err == nil then
            local gid1
            -- unfortnuately the parser incorrectly identifies the hex as a key value pair
            -- so f:o:o:b:a:r becomes {f = o:o:b:a:r}
            for k, v in pairs(gid1_out_parsed["read-result"]) do
                gid1 = k .. ":" .. v
            end
            gids.gid1 = gid1
        end

        return gids
    end

    local function nas_get_home_network_parsed()
        local key_map = {
            ["Home network"] = "home-network",
            MCC = "mcc",
            MNC = "mnc",
            Description = "description",
            ["Network name source"] = "network-name-source"
        }
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.nas_get_home_network(new_ctx, modem.primary_port)
        local out, err = cmd:combined_output()
        if err then return nil, wraperr.new(err) end

        return utils.parse_qmicli_output(out, key_map)
    end

    local function nas_get_signal_info_parsed()
        local key_map = {
            LTE = "lte",
            RSSI = "rssi",
            RSRQ = "rsrq",
            RSRP = "rsrp",
            SNR = "snr"
        }
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.nas_get_signal_info(new_ctx, modem.primary_port)
        local out, err = cmd:combined_output()
        if err then return nil, wraperr.new(err) end

        return utils.parse_qmicli_output(out, key_map)
    end

    modem.get_nas_info = function()
        local nas_infos = {}

        local home_network_info, hn_err = nas_get_home_network_parsed()
        if nh_err == nil and home_network_info then
            for k, v in pairs(home_network_info) do
                nas_infos[k] = v
            end
        end

        local signal_info, sig_err = nas_get_signal_info_parsed()
        if sig_err == nil and signal_info then
            for k, v in pairs(signal_info) do
                nas_infos[k] = v
            end
        end

        return nas_infos
    end
    -- Add other QMI-specific methods
    return true
end
