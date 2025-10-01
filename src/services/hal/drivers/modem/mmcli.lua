local exec = require "fibers.exec"

local function monitor_modems()
    return exec.command('mmcli', '-M')
end

local function inhibit(device)
    return exec.command('mmcli', '-m', device, '--inhibit')
end

local function connect(ctx, device, connection_string)
    connection_string = string.format("--simple-connect=%s", connection_string)
    return exec.command_context(ctx, 'mmcli', '-m', device, connection_string)
end

local function disconnect(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-m', device, '--simple-disconnect')
end

local function reset(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-m', device, '-r')
end

local function enable(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-m', device, '-e')
end

local function disable(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-m', device, '-d')
end

local function monitor_state(device)
    return exec.command('mmcli', '-m', device, '-w')
end

local function information(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-J', '-m', device)
end

local function sim_information(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-J', '-i', device)
end
local function location_status(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-J', '-m', device, '--location-status')
end

local function signal_setup(ctx, device, rate)
    return exec.command_context(ctx, 'mmcli', '-m', device, '--signal-setup=' .. tostring(rate))
end

local function signal_get(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-J', '-m', device, '--signal-get')
end

local function three_gpp_set_initial_eps_bearer_settings(ctx, device, settings)
    local settings_string = string.format("--3gpp-set-initial-eps-bearer-settings=%s", settings)
    return exec.command_context(ctx, 'mmcli', '-m', device, settings_string)
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
}
