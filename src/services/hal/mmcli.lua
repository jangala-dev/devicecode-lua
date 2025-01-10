local exec = require "fibers.exec"

local function monitor_modems()
    return exec.command('mmcli', '-M')
end

local function inhibit(device)
    return exec.command('mmcli', '-m', device, '--inhibit')
end

local function connect(ctx, device, connection_string)
    connection_string = string.format("--simple-connect=%s", connection_string)
    return exec.command_context(ctx, 'mmcli', '-m', device,
        connection_string)
end

local function disconnect(device)
    return exec.command('mmcli', '-m', device, '--simple-disconnect')
end

local function reset(device)
    return exec.command('mmcli', '-m', device, '-r')
end

local function factory_reset(code)
    return exec.command('mmcli', '-m', device, '--factory_reset=', code)
end

local function enable(device)
    return exec.command('mmcli', '-m', device, '-e')
end

local function disable(device)
    return exec.command('mmcli', '-m', device, '-d')
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
    return exec.command_context(ctx, 'mmcli', '-m', device, '--location-status')
end

local function signal_setup(ctx, device, rate)
    return exec.command_context(ctx, 'mmcli', '-m', device, '--signal-setup=', rate)
end

local function create_bearer(ctx, device, ...)
    local cmd_args = {}
    local num_args = select("#", ...)
    for i = 1, num_args do
        local kv_pair = select(i, ...)
        assert(type(kv_pair) == "table")
        assert(kv_pair.key)
        assert(kv_pair.value)
        table.insert(cmd_args, kv_pair.key .. "=" .. kv_pair.value)
    end
    local arg_string = table.concat(cmd_args, ',')
    arg_string = '"'.. arg_string .. '"'
    return exec.command_context(ctx, 'mmcli', '-m', device, '--create-bearer=', arg_string)
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
    signal_setup = signal_setup
}
