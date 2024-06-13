local fiber = require "fibers.fiber"
local exec = require "fibers.exec"
local json = require "dkjson"
local log = require "log"

-- there's a connect/disconnect event available directly from hostapd.
-- opkg install hostapd-utils will give you hostapd_cli

-- which you can run with an 'action file' (e.g. a simple shell script)
-- hostapd_cli -a/bin/hostapd_eventscript -B

-- the script will be get interface cmd mac as parameters e.g.
-- #!/bin/sh
-- logger -t $0 "hostapd event received $1 $2 $3"

-- will result in something like this in the logs
-- hostapd event received wlan1 AP-STA-CONNECTED xx:xx:xx:xx:xx:xx

local wifi_service = {}
wifi_service.__index = wifi_service

local function get_interfaces()
    local cmd = exec.command("ubus", "call", "network.wireless", "status")
    local raw, err = cmd:output()
    if err then return nil, err end
    local status, _, err = json.decode(raw)
    if err then return nil, err end

    local res = {}

    for _, radio in pairs(status) do
        for _, interface in ipairs(radio.interfaces) do
            table.insert(res, interface.ifname)
        end
    end

    return res, nil
end

local function publish_clients_count(interfaces, bus_connection)
    local count = 0
    for _, interface in ipairs(interfaces) do
        local cmd = exec.command("ubus", "call", "hostapd."..interface, "get_clients")
        local raw, err = cmd:output()
        if err then return nil, err end
        local status, _, err = json.decode(raw)
        if err then return nil, err end

        for _, _ in pairs(status.clients) do count = count + 1 end
    end

    log.info("new connected Wi-Fi users is:", count)

    bus_connection:publish({
        topic = "t.wifi.users",
        payload = json.encode({n="users", v=count}),
        retained = true
    })
end

local function client_counter(bus_connection)
    local interfaces, err = get_interfaces()
    if err then return error(err) end -- for now let's just crash

    local cmd = exec.command("/bin/sh", "-c", "logread -e 'associated' -f")
    local stdout = assert(cmd:stdout_pipe())
    local err = cmd:start()
    if err then return error(err) end -- ditto, just crash

    while true do
        assert(stdout:read_line())
        fiber.spawn(function ()
            publish_clients_count(interfaces, bus_connection)
        end)
    end
end

function wifi_service:start(ctx, bus_connection)
    log.trace("Starting Wi-Fi Service")

    fiber.spawn(function() client_counter(bus_connection) end)
end

return wifi_service