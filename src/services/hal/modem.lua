
local modem = {}

local function modem.detector(ctx, bus_conn)
    log.trace("HAL: Modem Detector: starting...")

    while true do
        -- First, we start the modem detector
        local cmd = exec.command('mmcli', '-M')
        local stdout = assert(cmd:stdout_pipe())
        local err = cmd:start()
        if err then
            log.error("Failed to start modem detection:", err)
            sleep.sleep(5)
        else
            -- Now we loop over every line of output
            for line in stdout:lines() do
                local is_added, address = utils.parse_monitor(line)

                if is_added==true then
                    log.trace("Modem Detector: detected at:", address)
                    modem_detect_channel:put(address)
                elseif is_added==false then
                    log.trace("Modem Detector: removed at:", address)
                    modem_remove_channel:put(address)
                end
            end
            cmd:wait()
        end
        stdout:close()
    end
end

local function modem.state_monitor(ctx, bus_conn, address, imei)
    log.trace("HAL: starting state monitor for: ", address, "-", imei)
    
    local cmd = exec.command('mmcli', '-m', address, '-w')
    local stdout = assert(cmd:stdout_pipe())
    local err = cmd:start()
    if err then
        log.error(string.format("Modem %s, imei: %s failed to start state monitoring", address, imei))
        sleep.sleep(5)
    else
        while true do
            for line in stdout:lines() do
                local state, _ = utils.parse_modem_monitor(line)
                bus_conn:publish({
                    topic = 'hal/capability/modem/'..imei..'/info/state',
                    payload = state
                })
            end
            cmd:wait()
        end
    end
    stdout:close()
end

local function modem.manager(ctx, bus_conn, device_add_q, )
    log.trace("GSM: Modem Manager starting")

    local modem_config = {}

    local driver_channel = channel.new()

    local function handle_removal(address)
        local device = modems.address[address]
        if not device then return end
        device.driver.ctx:cancel('removed')
        modems.address[address] = nil
        local imei = device.driver:imei()
        capabilities.modem[imei] = nil

        -- Remove previously retained message
        bus_conn:publish({
            topic = "hal/device/usb/"..imei,
            payload = "",
            retained = true
        })

        local modem_info = device_settings["modem"][address]
        if modem_info == nil then
            modem_info = device_settings["modem"]["default"]
        end

        -- 
        bus_conn:publish({
            topic = "hal/device/usb/"..imei,
            payload = {
                status = {
                    connected = false,
                    -- "time" = time.now()
                },
                identity = {
                    name = modem_info["name"],
                    model = driver:get_model(),
                    imei = driver:imei()
                },
                capabilities = modem_info["capability"]
            }
        })

        capabilities.modem[imei] = nil
        capabilities.geo[imei] = nil
        capabilities.time[imei] = nil
    end

    local function handle_detection(address)
        local driver = driver.new(context.with_cancel(ctx), address)
        modems.address[address] = new_modem(nil, nil, driver)
        fiber.spawn(function ()
            local err = driver:init()
            if err then
                log.error("GSM: Modem: Handle Detection: modem initialisation failed, removing modem")
                handle_removal(driver)
            else
                driver_channel:put(driver)
            end
        end)
    end

    local function handle_driver(driver)
        if driver.ctx:err() then return end

        -- Extract fingerprinting info
        local imei = driver:imei()
        local device = driver:device()
        local model = driver:get_model()
        local address = driver.address

        -- Check if an existing instance for that modem exists
        local instance = modems.imei[imei] or modems.device[device]
        if instance then
            log.trace("GSM: Modem: Handle Driver: driver detected for modem:", instance.name)
            instance:update_driver(driver)
        else
            log.trace("GSM: Modem: Handle Driver: driver detected for unknown modem:", driver.address)
            instance = modems.address[address]
            -- Modem is unknown, insert it into the tables with the relevant keys
            modems.imei[imei] = instance
            modems.device[device] = instance
        end

        local modem_info = device_settings["modem"][address]
        if modem_info == nil then
            modem_info = device_settings["modem"]["default"]
        end

        capability_channel:put(new_modem_capability(driver))

        if modem_info["capability"].geo then
            capabilities.geo[driver:imei()] = new_geo_capability(driver)
        end

        if modem_info["capability"].time then
            capabilities.time[driver:imei()] = new_time_capability(driver)
        end

        bus_conn:publish({
            topic = "hal/device/usb/"..imei,
            payload = {
                status = {
                    connected = true,
                    -- "time" = time.now()
                },
                identity = {
                    name = modem_info["name"],
                    model = model,
                    imei = imei
                },
                capabilities = modem_info["capability"]
            },
            retained = true
        })

        fiber.spawn(function () 
            state_monitor(ctx, bus_conn, address, imei)
        end)
    end

    local function handle_config(config)
        modem_config = config

        -- Handling known configs
        for name, mod_config in pairs(config.devices) do
            local instance = modems.name[name]
            if instance then
                instance:update_config(mod_config)
            else
                local id_field = mod_config.id_field
                local id_value = mod_config[id_field]
                instance = modems[id_field] and modems[id_field][id_value]
                if instance then
                    instance.name = name
                    instance:update_config(mod_config)
                else
                    -- Create a new instance and update the modems table
                    instance = new_modem(name, mod_config, nil) -- Driver to be associated later
                    modems.name[name] = instance
                    modems[id_field][id_value] = instance
                end
            end
        end

        -- Apply default configuration to all modems without specific configs
        if modem_config.defaults then
            for _, modem in pairs(modems.address) do
                if not modem.name then
                    log.trace("applying default config to:", modem.address)
                    modem:update_config(modem_config.defaults)
                end
            end
        end
    end

    while true do
        op.choice(
            modem_config_channel:get_op():wrap(handle_config),
            modem_detect_channel:get_op():wrap(handle_detection),
            modem_remove_channel:get_op():wrap(handle_removal),
            driver_channel:get_op():wrap(handle_driver)
        ):perform()
    end
end