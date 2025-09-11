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
    name = "wifi",
    radio_add_queue = queue.new(),
    radio_remove_queue = queue.new(),
    config_queue = queue.new()
}
wifi_service.__index = wifi_service

local function radio_listener(ctx, conn)
    log.trace(string.format(
        "%s - %s: Started",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    local band_init_sub = conn:subscribe({ 'hal', 'capability', 'band', '+' })
    band_init_sub:next_msg() -- wait for band to be initialised
    band_init_sub:unsubscribe()
    local wireless_sub = conn:subscribe({ 'hal', 'capability', 'wireless', '+' })

    while not ctx:err() do
        local wireless_msg = wireless_sub:next_msg_with_context(ctx)
        if wireless_msg and wireless_msg.payload then
            local wireless_cap = wireless_msg.payload
            if wireless_cap.connected then
                wifi_service.radio_add_queue:put(wireless_cap.device.index)
            else
                wifi_service.radio_remove_queue:put(wireless_cap.device.index)
            end
        end
    end
    wireless_sub:unsubscribe()

    log.trace(string.format(
        "%s - %s: Closed",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

local function publish_clients_count(interfaces, bus_connection)
    local count = 0
    for _, interface in ipairs(interfaces) do
        local cmd = exec.command("ubus", "call", "hostapd." .. interface, "get_clients")
        local raw, err = cmd:output()
        if err then return nil, err end
        local status, _, err = json.decode(raw)
        if err then return nil, err end

    local function add_radio(radio_index)
        if radios[radio_index] then
            log.warn("Radio already exists:", radio_index)
            return
        end
        log.info(string.format(
            "%s - %s: New radio detected (%s)",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            radio_index
        ))
        local radio = Radio.new(ctx, conn, radio_index)
        local config = radio_configs[radio_index]
        if config then
            radio:apply_config(config, report_period)
            radios[radio:get_index()] = radio
            local ssid_config = ssid_configs[radio:get_index()]
            if ssid_config then
                radio:remove_ssids()
                radio:apply_ssids(ssid_config)
            end
        end
        radios[radio_index] = radio
    end

    local function remove_radio(radio_index)
        local radio = radios[radio_index]
        if not radio then
            log.warn(string.format(
                "%s - %s: Radio not found for removal (%s)",
                ctx:value("service_name"),
                ctx:value("fiber_name"),
                radio_index
            ))
            return
        end
        log.info(string.format(
            "%s - %s: Removing radio (%s)",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            radio_index
        ))
        radio:remove()
        radios[radio_index] = nil
    end

    bus_connection:publish({
        topic = "t.wifi.users",
        payload = json.encode({ n = "users", v = count }),
        retained = true
    })
end

        --- Check SSIDs config section
        if not config.ssids then
            return "Missing ssids configuration"
        end
        if not (type(config.ssids) == "table") then
            return string.format("Invalid ssids type, should be a table but found %s", type(config.ssids))
        end
        for _, ssid_cfg in ipairs(config.ssids) do
            if not ssid_cfg.radios then
                return "SSID config missing radios"
            end
            if not (type(ssid_cfg.radios) == "table") then
                return string.format("SSID radios should be a table but found %s", type(ssid_cfg.radios))
            end
            if #ssid_cfg.radios == 0 then
                return "SSID config has empty radios list"
            end
            for _, radio_id in ipairs(ssid_cfg.radios) do
                if not (type(radio_id) == "string") then
                    return string.format("SSID radio id should be a string but found %s", type(radio_id))
                end
            end
            if not ssid_cfg.mode then
                return "SSID config missing mode"
            end
            if not INTERFACE_MODES[ssid_cfg.mode] then
                return string.format("SSID config has invalid mode: %s", ssid_cfg.mode)
            end
            if not ssid_cfg.mainflux_path then
                if not ssid_cfg.network then
                    return "SSID config missing network or mainflux_path"
                end
                if not (type(ssid_cfg.network) == "string") then
                    return string.format("SSID network should be a string but found %s", type(ssid_cfg.network))
                end
            end
        end

        --- Check Band Steering config section
        if not config.band_steering then
            return "Missing band_steering configuration"
        end
        if not (type(config.band_steering) == "table") then
            return string.format(
                "Invalid band_steering type, should be a table but found %s",
                type(config.band_steering)
            )
        end

    while true do
        assert(stdout:read_line())
        fiber.spawn(function()
            publish_clients_count(interfaces, bus_connection)
        end)
    end

    local function handle_config(msg)
        log.trace(string.format(
            "%s - %s: Config Received",
            ctx:value("service_name"),
            ctx:value("fiber_name")
        ))
        local config = msg and msg.payload or nil
        local err = validate_config(config)
        if err then
            log.error(string.format(
                "%s - %s: Config validation error: %s",
                ctx:value("service_name"),
                ctx:value("fiber_name"),
                err
            ))
            return
        end
        apply_config(config)
    end

    local band_sub = conn:subscribe({ 'hal', 'capability', 'band', '+' })
    band_sub:next_msg_with_context(ctx) -- wait for band driver to be initialised
    band_sub:unsubscribe()

    log.trace(string.format(
        "%s - %s: Started",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    local config_sub = conn:subscribe({ 'config', 'wifi' })
    while not ctx:err() do
        op.choice(
            wifi_service.radio_add_queue:get_op():wrap(add_radio),
            wifi_service.radio_remove_queue:get_op():wrap(remove_radio),
            wifi_service.config_queue:get_op():wrap(handle_config),
            config_sub:next_msg_op():wrap(handle_config),
            ctx:done_op()
        ):perform()
    end
    config_sub:unsubscribe()

    log.trace(string.format(
        "%s - %s: Closed",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

local function setup_radio(
    ctx,
    conn,
    index,
    report_period,
    band,
    channel,
    width,
    channels,
    txpower,
    country,
    interface)
    conn:publish(new_msg(
        { 'hal', 'capability', 'wireless', index, 'control', 'set_report_period' },
        { report_period }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'wireless', index, 'control', 'set_channels' },
        { band, channel, width, channels }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'wireless', index, 'control', 'set_txpower' },
        { txpower }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'wireless', index, 'control', 'set_country' },
        { country }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'wireless', index, 'control', 'set_enabled' },
        { true }
    ))
    local interface_sub = conn:request(new_msg(
        { 'hal', 'capability', 'wireless', index, 'control', 'add_interface' },
        interface
    ))
    local interface_response = interface_sub:next_msg()
    print("SECTION interface_response.payload.result:", interface_response.payload.result)
    conn:publish(new_msg(
        { 'hal', 'capability', 'wireless', index, 'control', 'apply' }
    ))
    return interface_response.payload.result
end

local function radio_listener(ctx, conn)
    local wireless_sub = conn:subscribe({ 'hal', 'capability', 'wireless', '+' })

    while not ctx:err() do
        local radio_msg = wireless_sub:next_msg()
        if radio_msg and radio_msg.payload then
            log.info("Received radio message:", json.encode(radio_msg.payload))
            local radio = conn:subscribe({ 'hal', 'device', 'wlan', radio_msg.payload.device.index }):next_msg()
            log.info("Radio details:", json.encode(radio.payload))
            if radio.payload.metadata.radioname == 'radio0' then
                local interface_id = setup_radio(
                    ctx,
                    conn,
                    radio_msg.payload.index,
                    10,
                    '2g',
                    'auto',
                    'HE20',
                    { 1, 6, 11 },
                    20,
                    'GB',
                    { 'test-ssid', 'psk2', 'adminjangala', 'lan' }
                )
                fiber.spawn(function()
                    sleep.sleep(60 * 5)
                    conn:publish(new_msg(
                        { 'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'delete_interface' },
                        { interface_id }
                    ))
                    conn:publish(new_msg(
                        { 'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'apply' }
                    ))
                end)
            elseif radio.payload.metadata.radioname == 'radio1' then
                local interface_id = setup_radio(
                    ctx,
                    conn,
                    radio_msg.payload.index,
                    10,
                    '5g',
                    'auto',
                    'HE80',
                    { 36, 40, 44, 48 },
                    20,
                    'GB',
                    { 'test-ssid-5g', 'psk2', 'adminjangala', 'lan' }
                )
                fiber.spawn(function()
                    sleep.sleep(60 * 5)
                    conn:publish(new_msg(
                        { 'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'delete_interface' },
                        { interface_id }
                    ))
                    conn:publish(new_msg(
                        { 'hal', 'capability', 'wireless', radio_msg.payload.index, 'control', 'apply' }
                    ))
                end)
            end
        end
    end
end

local function build_basic_dawn(ctx, conn)
    local band_sub = conn:subscribe({'hal', 'capability', 'band', '+'})
    local band_msg, ctx_err = band_sub:next_msg_with_context(ctx)
    if ctx_err then return end
    local band_idx = band_msg.payload.index
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_kick_mode' },
        { 'both' }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_band_priority' },
        { '2g', 80 }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_band_priority' },
        { '5g', 100 }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_client_kicking' },
        { '2g', -50, 5, 10, 5, -20, 1 }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_client_kicking' },
        { '5g', -50, 5, 10, 5, -20, 1 }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_support_bonus' },
        { '2g', 'ht', 20 }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_support_bonus' },
        { '5g', 'ht', 30 }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_support_bonus' },
        { '5g', 'vht', 40 }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_update_freq' },
        { { client = 15, chan_util = 5, hostapd = 10 } }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_client_inactive_kickoff' },
        { 60 }
    ))
    conn:request(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'set_client_cleanup' },
        { 30 }
    ))
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'apply' }
    ))
    sleep.sleep(20)
    conn:publish(new_msg(
        { 'hal', 'capability', 'band', band_idx, 'control', 'apply' }
    ))
end

function wifi_service:start(ctx, conn)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    fiber.spawn(function() radio_listener(ctx, conn) end)
    fiber.spawn(function() build_basic_dawn(ctx, conn) end)
end

return wifi_service
