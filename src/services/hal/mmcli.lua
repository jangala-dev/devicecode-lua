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

local function restart(device)
    return exec.command('mmcli', '-m', device, '-r')
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

return {
    monitor_modems = monitor_modems,
    inhibit = inhibit,
    connect = connect,
    disconnect = disconnect,
    restart = restart,
    enable = enable,
    disable = disable,
    monitor_state = monitor_state,
    information = information
}