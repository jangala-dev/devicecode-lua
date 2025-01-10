local exec = require "fibers.exec"

local function monitor_modems()
    return exec.command('mmcli', '-M')
end

local function inhibit(device)
    return exec.command('mmcli', '-m', device, '--inhibit')
end

local function connect(device)
    return exec.command('mmcli', '-m', device,
        '--simple-connect="apn=mobile.o2.co.uk,user=o2web,password=password,allowed-auth=pap"')
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
    information = information
}
