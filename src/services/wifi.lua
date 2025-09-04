local fiber = require "fibers.fiber"
local exec = require "fibers.exec"
local sleep = require "fibers.sleep"
local json = require "dkjson"
local log = require "services.log"
local new_msg = require "bus".new_msg
local dump = require "fibers.utils.helper".dump

-- there's a connect/disconnect event available directly from hostapd.
-- opkg install hostapd-utils will give you hostapd_cli

-- which you can run with an 'action file' (e.g. a simple shell script)
-- hostapd_cli -a/bin/hostapd_eventscript -B

-- the script will be get interface cmd mac as parameters e.g.
-- #!/bin/sh
-- logger -t $0 "hostapd event received $1 $2 $3"

-- will result in something like this in the logs
-- hostapd event received wlan1 AP-STA-CONNECTED xx:xx:xx:xx:xx:xx

-- I've used `iw event` for connection and disconnection events instead of the method above

local wifi_service = {
    name = "wifi"
}
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

local function radio_listener(ctx, conn)
    local wireless_sub = conn:subscribe({'hal', 'capability', 'wireless', '+'})

    while not ctx:err() do
        local radio_msg = wireless_sub:next_msg()
        if radio_msg and radio_msg.payload then
            log.info("Received radio message:", json.encode(radio_msg.payload))
            local radio = conn:subscribe({'hal', 'device', 'wlan', radio_msg.payload.device.index}):next_msg()
            log.info("Radio details:", json.encode(radio.payload))
            if radio.payload.metadata.radioname == 'radio0' then
                conn:publish(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'set_report_period'},
                    { 10 }
                ))
                conn:publish(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'set_channels'},
                    { '2g', 'auto', 'HE20', {1, 6, 11} }
                ))
                conn:publish(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'set_txpower'},
                    { 20 }
                ))
                conn:publish(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'set_country'},
                    { 'GB' }
                ))
                conn:publish(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'set_enabled'},
                    { true }
                ))
                local interface_sub = conn:request(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'add_interface'},
                    {'test-ssid', 'psk2', 'adminjangala', 'lan'}
                ))
                local interface_response = interface_sub:next_msg()
                print("SECTION interface_response.payload.result:", interface_response.payload.result)
                conn:publish(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'apply'}
                ))
                sleep.sleep(30)
                conn:publish(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'delete_interface'},
                    { interface_response.payload.result }
                ))
                conn:publish(new_msg(
                    {'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'apply'}
                ))
                sleep.sleep(30)
            end
        end
    end
end

local function build_basic_wireless(ctx, conn)
    conn:publish(new_msg(
        {'hal', 'capability', 'uci', '1', 'control', 'set'},
        {''}
    ))
end

function wifi_service:start(ctx, conn)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    fiber.spawn(function() radio_listener(ctx, conn) end)
end

return wifi_service
