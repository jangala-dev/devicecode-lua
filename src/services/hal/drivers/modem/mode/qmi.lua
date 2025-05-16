local exec = require 'fibers.exec'
local sleep = require "fibers.sleep"
local context = require 'fibers.context'
local wraperr = require "wraperr"
local qmicli = require "services.hal.drivers.modem.qmicli"
local utils = require "services.hal.utils"
local log = require "log"

local CMD_TIMEOUT = 3

-- driver/mode/qmi.lua
return function(modem)
    modem.is_sim_inserted = function()
        local new_ctx = context.with_timeout(modem.ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_get_card_status(new_ctx, modem.primary_port)
        local out, cmd_err = cmd:combined_output()
        if cmd_err then return nil, cmd_err end

        local status, parse_err = utils.parse_slot_monitor(out)
        if parse_err then return nil, parse_err end
        return status == 'present', nil
    end

    modem.set_power_low = function(ctx)
        local new_ctx = context.with_timeout(ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_sim_power_off(new_ctx, modem.primary_port)
        return cmd:combined_output()
    end

    modem.set_power_high = function(ctx)
        local new_ctx = context.with_timeout(ctx, CMD_TIMEOUT)
        local cmd = qmicli.uim_sim_power_on(new_ctx, modem.primary_port)
        return cmd:combined_output()
    end

    modem.monitor_slot_status = function()
        local cmd = qmicli.uim_monitor_slot_status(modem.primary_port)
        local stdout = assert(cmd:stdout_pipe())
        local cmd_err = cmd:start()
        if cmd_err then return nil, nil, cmd_err end
        local data = ""
        local read_func = function()
            return stdout:read_line_op("keep"):wrap(function(line)
                if line == nil then return nil end
                data = data .. line
                local slot_status, err = utils.parse_slot_monitor(data)
                if err then return nil end
                data = ""
                return slot_status == 'present'
            end)
        end
        local cancel_fn = function()
            cmd:kill()
            stdout:close()
        end

        return read_func, cancel_fn, nil
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
        if gid1_parse_err == nil and gid1_out_parsed["read-result"] then
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

    modem.nas_get_rf_band_info = function()
        local key_map = {
            ["Band Information"] = "band-information",
            ["Radio Interface"] = "radio-interface",
            ["Active Band Class"] = "active-band-class",
            ["Active Channel"] = "active-channel",
            ["Band Information (Extended)"] = "band-information-extended"
        }
        local band_info_cmd = qmicli.nas_get_rf_band_info(
            context.with_timeout(modem.ctx, CMD_TIMEOUT),
            modem.primary_port
        )

        local band_info_out, band_info_err = band_info_cmd:combined_output()
        if band_info_err then return nil, band_info_err end

        local band_info, parse_err = utils.parse_qmicli_output(band_info_out, key_map)
        if parse_err then return nil, parse_err end
        return band_info
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
        if hn_err == nil and home_network_info then
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
