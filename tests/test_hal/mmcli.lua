local function monitor_modems(bus_conn)
    print("monitor_modems")
end

local function inhibit(device)
    print("monitor_modems")
end

local function connect(device)
    print("monitor_modems")
end

local function disconnect(device)
    print("monitor_modems")
end

local function restart(device)
    print("monitor_modems")
end

local function enable(device)
    print("monitor_modems")
end

local function disable(device)
    print("monitor_modems")
end

local function monitor_state(device)
    print("monitor_modems")
end

local function information(ctx, device)
    print("monitor_modems")
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