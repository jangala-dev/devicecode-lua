local commands = require "tests.utils.ShimCommands"
local modem_registry = require 'tests.hal.harness.devices.modem_registry'

-- For each function we create and track shim commands per *port*.

local uim_get_card_status_cmds = {}
local function uim_get_card_status(ctx, port)
    uim_get_card_status_cmds[port] = commands.new_command()
    return uim_get_card_status_cmds[port]
end

local uim_sim_power_off_cmds = {}
local function uim_sim_power_off(ctx, port)
    local cmd = commands.new_command()
    uim_sim_power_off_cmds[port] = cmd

    local modem = modem_registry.get_by_qmi_port(port)
    if modem and modem.on_qmi_uim_sim_power_off then
        cmd.on_start = function()
            return modem:on_qmi_uim_sim_power_off(cmd, port)
        end
    end

    return cmd
end

local uim_sim_power_on_cmds = {}
local function uim_sim_power_on(ctx, port)
    local cmd = commands.new_command()
    uim_sim_power_on_cmds[port] = cmd

    local modem = modem_registry.get_by_qmi_port(port)
    if modem and modem.on_qmi_uim_sim_power_on then
        cmd.on_start = function()
            return modem:on_qmi_uim_sim_power_on(cmd, port)
        end
    end

    return cmd
end

local uim_monitor_slot_status_cmds = {}
local function uim_monitor_slot_status(port)
    local cmd = commands.new_command()
    uim_monitor_slot_status_cmds[port] = cmd

    local modem = modem_registry.get_by_qmi_port(port)
    if modem and modem.on_qmi_uim_monitor_start then
        cmd.on_start = function()
            return modem:on_qmi_uim_monitor_start(cmd, port)
        end
    end

    return cmd
end

local uim_read_transparent_cmds = {}
local function uim_read_transparent(ctx, port, address_string)
    uim_read_transparent_cmds[port] = commands.new_command()
    return uim_read_transparent_cmds[port]
end

local nas_get_rf_band_info_cmds = {}
local function nas_get_rf_band_info(ctx, port)
    nas_get_rf_band_info_cmds[port] = commands.new_command()
    return nas_get_rf_band_info_cmds[port]
end

local nas_get_home_network_cmds = {}
local function nas_get_home_network(ctx, port)
    nas_get_home_network_cmds[port] = commands.new_command()
    return nas_get_home_network_cmds[port]
end

local nas_get_serving_system_cmds = {}
local function nas_get_serving_system(ctx, port)
    nas_get_serving_system_cmds[port] = commands.new_command()
    return nas_get_serving_system_cmds[port]
end

local nas_get_signal_info_cmds = {}
local function nas_get_signal_info(ctx, port)
    nas_get_signal_info_cmds[port] = commands.new_command()
    return nas_get_signal_info_cmds[port]
end

return {
    uim_get_card_status = uim_get_card_status,
    uim_sim_power_off = uim_sim_power_off,
    uim_sim_power_on = uim_sim_power_on,
    uim_monitor_slot_status = uim_monitor_slot_status,
    uim_read_transparent = uim_read_transparent,

    nas_get_rf_band_info = nas_get_rf_band_info,
    nas_get_home_network = nas_get_home_network,
    nas_get_serving_system = nas_get_serving_system,
    nas_get_signal_info = nas_get_signal_info,

    -- Exposed for test inspection, keyed by port
    uim_get_card_status_cmds = uim_get_card_status_cmds,
    uim_sim_power_off_cmds = uim_sim_power_off_cmds,
    uim_sim_power_on_cmds = uim_sim_power_on_cmds,
    uim_monitor_slot_status_cmds = uim_monitor_slot_status_cmds,
    uim_read_transparent_cmds = uim_read_transparent_cmds,
    nas_get_rf_band_info_cmds = nas_get_rf_band_info_cmds,
    nas_get_home_network_cmds = nas_get_home_network_cmds,
    nas_get_serving_system_cmds = nas_get_serving_system_cmds,
    nas_get_signal_info_cmds = nas_get_signal_info_cmds,
}
