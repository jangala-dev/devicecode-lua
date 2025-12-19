local channel = require 'fibers.channel'
local commands = require 'tests.utils.ShimCommands'
local modem_registry = require 'tests.hal.harness.devices.modem_registry'

local monitor_modems_cmd = commands.new_command() -- We only ever need one instance
local function monitor_modems()
    return monitor_modems_cmd
end

local inhibit_cmds = {}
local function inhibit(device)
    local cmd = commands.new_command()
    inhibit_cmds[device] = cmd

    local modem = modem_registry.get_by_address(device)
    if modem and modem.on_mmcli_inhibit_start then
        cmd.on_start = function()
            return modem:on_mmcli_inhibit_start(cmd)
        end
    end
    if modem and modem.on_mmcli_inhibit_end then
        cmd.on_kill = function()
            modem:on_mmcli_inhibit_end(cmd)
        end
    end

    return cmd
end

local connect_cmds = {}
local function connect(ctx, device, connection_string)
    if not connect_cmds[device] then
        connect_cmds[device] = {}
    end
    local cmd = commands.new_command()
    table.insert(connect_cmds[device], cmd)

    local modem = modem_registry.get_by_address(device)
    if modem and modem.on_mmcli_connect then
        cmd.on_start = function()
            return modem:on_mmcli_connect(cmd, connection_string)
        end
    end

    return cmd
end

local disconnect_cmds = {}
local function disconnect(ctx, device)
    local cmd = commands.new_command()
    disconnect_cmds[device] = cmd

    local modem = modem_registry.get_by_address(device)
    if modem and modem.on_mmcli_disconnect then
        cmd.on_start = function()
            return modem:on_mmcli_disconnect(cmd)
        end
    end

    return cmd
end

local reset_cmds = {}
local function reset(ctx, device)
    local cmd = commands.new_command()
    reset_cmds[device] = cmd

    local modem = modem_registry.get_by_address(device)
    if modem and modem.on_mmcli_reset then
        cmd.on_start = function()
            return modem:on_mmcli_reset(cmd)
        end
    end

    return cmd
end

local enable_cmds = {}
local function enable(ctx, device)
    local cmd = commands.new_command()
    enable_cmds[device] = cmd

    local modem = modem_registry.get_by_address(device)
    if modem and modem.on_mmcli_enable then
        cmd.on_start = function()
            return modem:on_mmcli_enable(cmd)
        end
    end

    return cmd
end

local disable_cmds = {}
local function disable(ctx, device)
    local cmd = commands.new_command()
    disable_cmds[device] = cmd

    local modem = modem_registry.get_by_address(device)
    if modem and modem.on_mmcli_disable then
        cmd.on_start = function()
            return modem:on_mmcli_disable(cmd)
        end
    end

    return cmd
end

local monitor_state_cmds = {}
local function monitor_state(device)
    local cmd = commands.new_command()
    monitor_state_cmds[device] = cmd

    local modem = modem_registry.get_by_address(device)
    if modem and modem.on_mmcli_monitor_state_start then
        cmd.on_start = function()
            return modem:on_mmcli_monitor_state_start(cmd)
        end
    end

    return cmd
end

local information_cmds = {}
local function information(ctx, device)
    if not information_cmds[device] then
        information_cmds[device] = commands.new_static_command()
    end
    return information_cmds[device]
end

local sim_information_cmds = {}
local function sim_information(ctx, device)
    sim_information_cmds[device] = commands.new_command()
    return sim_information_cmds[device]
end

local location_status_cmds = {}
local function location_status(ctx, device)
    location_status_cmds[device] = commands.new_command()
    return location_status_cmds[device]
end

local signal_setup_cmds = {}
local function signal_setup(ctx, device, rate)
    local cmd = commands.new_command()
    signal_setup_cmds[device] = cmd

    local modem = modem_registry.get_by_address(device)
    if modem and modem.on_mmcli_signal_setup then
        cmd.on_start = function()
            return modem:on_mmcli_signal_setup(cmd, rate)
        end
    end

    return cmd
end

local signal_get_cmds = {}
local function signal_get(ctx, device)
    signal_get_cmds[device] = commands.new_command()
    return signal_get_cmds[device]
end

local three_gpp_set_initial_eps_bearer_settings_cmds = {}
local function three_gpp_set_initial_eps_bearer_settings(ctx, device, settings)
    local settings_string = string.format("--3gpp-set-initial-eps-bearer-settings=%s", settings)
    three_gpp_set_initial_eps_bearer_settings_cmds[device] = commands.new_command()
    return three_gpp_set_initial_eps_bearer_settings_cmds[device]
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
    information = information,
    sim_information = sim_information,
    location_status = location_status,
    signal_setup = signal_setup,
    signal_get = signal_get,
    three_gpp_set_initial_eps_bearer_settings = three_gpp_set_initial_eps_bearer_settings,
    -- Exposed for test inspection
    inhibit_cmds = inhibit_cmds,
    connect_cmds = connect_cmds,
    disconnect_cmds = disconnect_cmds,
    reset_cmds = reset_cmds,
    enable_cmds = enable_cmds,
    disable_cmds = disable_cmds,
    monitor_state_cmds = monitor_state_cmds,
    information_cmds = information_cmds,
    sim_information_cmds = sim_information_cmds,
    location_status_cmds = location_status_cmds,
    signal_setup_cmds = signal_setup_cmds,
    signal_get_cmds = signal_get_cmds,
    three_gpp_set_initial_eps_bearer_settings_cmds = three_gpp_set_initial_eps_bearer_settings_cmds
}
