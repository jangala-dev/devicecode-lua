local commands = {}

local function set_command(name, cmd)
    commands[name] = cmd
end

local function monitor_modems()
    if not commands.monitor_modems then error("monitor_modems command not set up") end
    return commands.monitor_modems
end

local function inhibit(device)
    if not commands.inhibit then error("inhibit command not set up") end
    return commands.inhibit
end

local function connect(ctx, device, connection_string)
    if not commands.connect then error("connect command not set up") end
    return commands.connect
end

local function disconnect(ctx, device)
    if not commands.disconnect then error("disconnect command not set up") end
    return commands.disconnect
end

local function reset(ctx, device)
    if not commands.reset then error("reset command not set up") end
    return commands.reset
end

local function enable(ctx, device)
    if not commands.enable then error("enable command not set up") end
    return commands.enable
end

local function disable(ctx, device)
    if not commands.disable then error("disable command not set up") end
    return commands.disable
end

local function monitor_state(device)
    if not commands.monitor_state then error("monitor_state command not set up") end
    return commands.monitor_state
end

local function information(ctx, device)
    if not commands.information then error("information command not set up") end
    return commands.information
end

local function sim_information(ctx, device)
    if not commands.sim_information then error("sim_information command not set up") end
    return commands.sim_information
end

local function location_status(ctx, device)
    if not commands.location_status then error("location_status command not set up") end
    return commands.location_status
end

local function signal_setup(ctx, device, rate)
    if not commands.signal_setup then error("signal_setup command not set up") end
    return commands.signal_setup
end

local function signal_get(ctx, device)
    if not commands.signal_get then error("signal_get command not set up") end
    return commands.signal_get
end

local function three_gpp_set_initial_eps_bearer_settings(ctx, device, settings)
    if not commands.three_gpp_set_initial_eps_bearer_settings then
        error("three_gpp_set_initial_eps_bearer_settings command not set up")
    end
    return commands.three_gpp_set_initial_eps_bearer_settings
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

    -- Test harness only
    set_command = set_command,
}
