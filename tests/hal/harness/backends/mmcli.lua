local channel = require 'fibers.channel'
local commands = require 'tests.utils.ShimCommands'

local monitor_modems_cmd = commands.new_command() -- We only ever need one instance
local function monitor_modems()
    return monitor_modems_cmd
end

local inhibit_cmds = {}
local function inhibit(device)
    inhibit_cmds[device] = commands.new_command()
    return inhibit_cmds[device]
end

local connect_cmds = {}
local function connect(ctx, device, connection_string)
    if not connect_cmds[device] then
        connect_cmds[device] = {}
    end
    table.insert(connect_cmds[device], commands.new_command())
    return connect_cmds[device][#connect_cmds[device]]
end

local disconnect_cmds = {}
local function disconnect(ctx, device)
    disconnect_cmds[device] = commands.new_command()
    return disconnect_cmds[device]
end

local reset_cmds = {}
local function reset(ctx, device)
    reset_cmds[device] = commands.new_command()
    return reset_cmds[device]
end

local enable_cmds = {}
local function enable(ctx, device)
    enable_cmds[device] = commands.new_command()
    return enable_cmds[device]
end

local disable_cmds = {}
local function disable(ctx, device)
    disable_cmds[device] = commands.new_command()
    return disable_cmds[device]
end

local monitor_state_cmds = {}
local function monitor_state(device)
    monitor_state_cmds[device] = commands.new_command()
    return monitor_state_cmds[device]
end

local information_cmds = {}
local function information(ctx, device)
    print(device)
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
    signal_setup_cmds[device] = commands.new_command()
    return signal_setup_cmds[device]
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
