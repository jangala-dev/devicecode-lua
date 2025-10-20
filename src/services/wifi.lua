local fiber = require "fibers.fiber"
local op = require "fibers.op"
local queue = require "fibers.queue"
local log = require "services.log"
local gen = require "services.wifi.gen"
local service = require "service"
local new_msg = require "bus".new_msg
local utils = require "services.wifi.utils"

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

local INTERFACE_MODES = {
    access_point = "ap",
    client = "sta",
    adhoc = "adhoc",
    mesh = "mesh",
    monitor = "monitor"
}


local Radio = {}
Radio.__index = Radio

function Radio:apply_config(config, report_period)
    local reqs = {}

    local clear_req = self.conn:request(new_msg(
        { 'hal', 'capability', 'wireless', self.index, 'control', 'clear_radio_config' }
    ))
    local resp, err = clear_req:next_msg_with_context(self.ctx)
    clear_req:unsubscribe()
    if err or resp and resp.payload and resp.payload.err then
        log.error(string.format(
            "%s - %s: Radio %s clear config error: %s",
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name"),
            self.index or "(unknown)",
            err or resp.payload.err
        ))
        return
    end

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'wireless', self.index, 'control', 'set_report_period' },
        { report_period }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'wireless', self.index, 'control', 'set_channels' },
        {
            config.band,
            config.channel,
            config.htmode,
            config.channels
        }
    ))

    if config.txpower then
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'wireless', self.index, 'control', 'set_txpower' },
            { config.txpower }
        ))
    end

    if config.country then
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'wireless', self.index, 'control', 'set_country' },
            { config.country }
        ))
    end

    if config.disabled ~= nil then
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'wireless', self.index, 'control', 'set_enabled' },
            { not config.disabled }
        ))
    end

    fiber.spawn(function()
        local results = {}
        for i, req in pairs(reqs) do
            local resp, err = req:next_msg_with_context(self.ctx)
            req:unsubscribe()
            if err then return end
            results[i] = resp and resp.payload or {}
        end
        if err then
            log.error(string.format(
                "%s - %s: Radio %s config error: %s",
                self.ctx:value("service_name"),
                self.ctx:value("fiber_name"),
                self.index or "(unknown)",
                err
            ))
            return
        end
        for _, result in pairs(results) do
            if result.err then
                log.error(string.format(
                    "%s - %s: Radio %s config error: %s",
                    self.ctx:value("service_name"),
                    self.ctx:value("fiber_name"),
                    self.index or "(unknown)",
                    result.err
                ))
            end
        end

        local req = self.conn:request(new_msg(
            { 'hal', 'capability', 'wireless', self.index, 'control', 'apply' }
        ))
        local resp, ctx_err = req:next_msg_with_context(self.ctx)
        req:unsubscribe()
        if ctx_err or resp and resp.payload and resp.payload.err then
            log.error(string.format(
                "%s - %s: Radio %s apply config error: %s",
                self.ctx:value("service_name"),
                self.ctx:value("fiber_name"),
                self.index or "(unknown)",
                ctx_err or resp.payload.err
            ))
            return
        end
        log.info(string.format(
            "%s - %s: Radio %s applied configuration",
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name"),
            self.index or "(unknown)"
        ))
    end)
end

function Radio:make_mainflux_ssids(mainflux_cfg, encryption, mode)
    local mf_ssids = {}
    for _, ssid_cfg in ipairs(mainflux_cfg or {}) do
        -- edge case for incorrect mainflux naming that uses jng instead of adm
        local name = ssid_cfg.name == "jng" and "adm" or ssid_cfg.name
        mf_ssids[#mf_ssids + 1] = {
            name = ssid_cfg.ssid,
            encryption = encryption,
            password = ssid_cfg.password,
            network = name,
            mode = mode
        }
    end
    return mf_ssids
end

function Radio:apply_ssids(ssid_configs)
    fiber.spawn(function()
        for _, ssid in ipairs(ssid_configs) do
            local req = self.conn:request(new_msg(
                { 'hal', 'capability', 'wireless', self.index, 'control', 'add_interface' },
                {
                    ssid.name,
                    ssid.encryption or "none",
                    ssid.password or "",
                    ssid.network,
                    INTERFACE_MODES[ssid.mode],
                    {
                        enable_steering = ssid.has_band_steering or false
                    }
                }
            ))
            local resp, err = req:next_msg_with_context(self.ctx)
            req:unsubscribe()
            if err or resp and resp.payload and resp.payload.err then
                log.error(string.format(
                    "%s - %s: Radio %s add SSID error: %s",
                    self.ctx:value("service_name"),
                    self.ctx:value("fiber_name"),
                    self.index or "(unknown)",
                    err or resp.payload.err
                ))
            else
                self.ssids[#self.ssids + 1] = resp.payload.result
            end
        end

        local req = self.conn:request(new_msg(
            { 'hal', 'capability', 'wireless', self.index, 'control', 'apply' }
        ))
        local resp, ctx_err = req:next_msg_with_context(self.ctx)
        req:unsubscribe()
        if ctx_err or resp and resp.payload and resp.payload.err then
            log.error(string.format(
                "%s - %s: Radio %s failed to apply SSIDs, reason: %s",
                self.ctx:value("service_name"),
                self.ctx:value("fiber_name"),
                self.index or "(unknown)",
                ctx_err or resp.payload.err
            ))
            return
        end
        log.info(string.format(
            "%s - %s: Radio %s applied %d SSIDs",
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name"),
            self.index or "(unknown)",
            #ssid_configs
        ))
    end)
end

function Radio:remove_ssids()
    local reqs = {}
    for _, id in ipairs(self.ssids) do
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'wireless', self.index, 'control', 'delete_interface' },
            { id }
        ))
    end
    for _, req in ipairs(reqs) do
        local resp, err = req:next_msg_with_context(self.ctx)
        req:unsubscribe()
        if err or resp and resp.payload and resp.payload.err then
            log.error(string.format(
                "%s - %s: Radio %s remove SSID error: %s",
                self.ctx:value("service_name"),
                self.ctx:value("fiber_name"),
                self.index or "(unknown)",
                err or resp.payload.err
            ))
        end
    end
    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'wireless', self.index, 'control', 'apply' }
    ))
    local resp, ctx_err = req:next_msg_with_context(self.ctx)
    req:unsubscribe()
    if ctx_err or resp and resp.payload and resp.payload.err then
        log.error(string.format(
            "%s - %s: Radio %s apply after remove SSIDs error: %s",
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name"),
            self.index or "(unknown)",
            ctx_err or resp.payload.err
        ))
        return
    end
    self.ssids = {}
end

function Radio:_report_metrics(ctx, conn)
    -- local num_clients = 0
    -- local interface_names = {}

    -- local interface_stat_targets = {
    --     txpower = { 'txpower' },
    --     channel = { 'channel', 'chan' },
    --     -- noise = { '' } not currently supplied by wireless driver

    --     rx_bytes = { 'rx_bytes' },
    --     rx_packets = { 'rx_packets' },
    --     rx_dropped = { 'rx_dropped' },
    --     rx_errors = { 'rx_errors' },

    --     tx_bytes = { 'tx_bytes' },
    --     tx_packets = { 'tx_packets' },
    --     tx_dropped = { 'tx_dropped' },
    --     tx_errors = { 'tx_errors' },
    --     ssid = { 'ssid'}
    -- }
    -- local interface_stat_subs = {}
    -- for name, path in pairs(interface_stat_targets) do
    --     interface_stat_subs[name] = conn:subscribe(
    --         { 'hal', 'capability', 'wireless', self.index, 'info', 'interface', '+', unpack(path) }
    --     )
    -- end

    -- -- local interface_ssid_sub = conn:subscribe(
    -- --     { 'hal', 'capability', 'wireless', self.index, 'info', 'interface', '+',  }
    -- -- )
    -- local client_sub = conn:subscribe(
    --     { 'hal', 'capability', 'wireless', self.index, 'info', 'interface', '+', 'client', '+' }
    -- )

    -- while not ctx:err() do
    --     local ops = {}
    --     for name, sub in pairs(interface_stat_subs) do
    --         ops[#ops + 1] = sub:next_msg_op():wrap(function (msg)
    --             local interface = msg.topic[7]
    --             if msg.payload and interface and interface_names[interface] then
    --                 local value = msg.payload
    --                 conn:publish(new_msg(
    --                     { 'wifi', self.index, interface_names[interface], name },
    --                     value
    --                 ))
    --             end
    --             return msg
    --         end)
    --         if name == "ssid" then
    --             ops[#ops]:wrap(function (msg)
    --                 local interface = msg.topic[7]
    --                 if msg.payload and interface then
    --                     interface_names[interface] = string.find(msg.payload, "-admin") and "admin" or "jangala"
    --                 end
    --                 return msg
    --             end)
    --         end
    --     end
    --     op.choice(
    --         client_sub:next_msg_op():wrap(function (msg)
    --             if msg.payload then
    --                 if msg.payload.connected then
    --                     num_clients = num_clients + 1
    --                 else
    --                     if num_clients <= 0  then
    --                         log.warn(string.format(
    --                             "%s - %s: num_clients entering negative, adjusting back to 0",
    --                             ctx:value("service_name"),
    --                             ctx:value("fiber_name")
    --                         ))
    --                         num_clients = 0
    --                     else
    --                         num_clients = num_clients - 1
    --                     end
    --                 end
    --             end
    --         end)
    --     )
    -- end
end

function Radio:get_index()
    return self.index
end

function Radio:remove()
    self.ctx:cancel("Radio removed")
end

function Radio.new(ctx, conn, index)
    local self = setmetatable({}, Radio)
    self.ctx = ctx
    self.conn = conn
    self.index = index
    self.ssids = {}
    return self
end

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

local function radio_manager(ctx, conn)
    local radios = {}
    local radio_configs = {}
    local report_period = nil
    local ssid_configs = {}

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

    local function validate_config(config)
        if not config then
            return "Missing configuration"
        end
        --- Check Radios config section
        if not config.radios then
            return "Missing radios configuration"
        end
        if not (type(config.radios) == "table") then
            return string.format("Invalid radios type, should be a table but found %s", type(config.radios))
        end
        for _, radio_cfg in ipairs(config.radios) do
            if not radio_cfg.name then
                return "Radio config missing name"
            end
            if not radio_cfg.band then
                return string.format("Radio %s missing band", radio_cfg.name)
            end
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

        local globals = config.band_steering.globals
        if not globals then
            return "Missing band_steering globals configuration"
        end
        if not (type(globals) == "table") then
            return string.format("Invalid band_steering globals type, should be a table but found %s", type(globals))
        end

        -- Validate the kicking settings
        if not globals.kicking then
            return "Missing band_steering kicking configuration"
        end
        local required_kicking_fields = {
            "kick_mode",
            "bandwidth_threshold",
            "kicking_threshold",
            "evals_before_kick"
        }
        for _, field in ipairs(required_kicking_fields) do
            if globals.kicking[field] == nil then
                return string.format("Missing band_steering kicking field: %s", field)
            end
        end

        local timing = config.band_steering.timings
        if not timing then
            return "Missing band_steering timing configuration"
        end
        if type(timing) ~= 'table' then
            return string.format("Invalid timing type, should be a table but found %s", type(timing))
        end

        -- Check updates structure
        if not timing.updates then
            return "Missing band_steering updates timing configuration"
        end
        if type(timing.updates) ~= 'table' then
            return string.format("Invalid updates timing type, should be a table but found %s", type(timing.updates))
        end
        local required_update_fields = {
            "client",
            "chan_util",
            "hostapd"
        }
        for _, field in ipairs(required_update_fields) do
            if timing.updates[field] == nil then
                return string.format("Missing band_steering updates timing field: %s", field)
            end
        end

        -- Check cleanup structure
        if not timing.cleanup then
            return "Missing band_steering cleanup timing configuration"
        end
        if type(timing.cleanup) ~= 'table' then
            return string.format("Invalid cleanup timing type, should be a table but found %s", type(timing.cleanup))
        end
        local required_cleanup_fields = {
            "client",
            "probe",
            "ap"
        }
        for _, field in ipairs(required_cleanup_fields) do
            if timing.cleanup[field] == nil then
                return string.format("Missing band_steering cleanup timing field: %s", field)
            end
        end

        -- Check inactive_client_kickoff
        if timing.inactive_client_kickoff == nil then
            return "Missing band_steering inactive_client_kickoff timing configuration"
        end

        local bands = config.band_steering.bands
        if not bands then
            return "Missing band_steering bands configuration"
        end
        if not (type(bands) == "table") then
            return string.format("Invalid band_steering bands type, should be a table but found %s", type(bands))
        end

        -- Validate each band configuration
        for band_name, band_cfg in pairs(bands) do
            if not (type(band_cfg) == "table") then
                return string.format("Invalid band_steering band type for %s, should be a table but found %s", band_name, type(band_cfg))
            end

            -- Check initial score
            if band_cfg.initial_score == nil then
                return string.format("Missing initial_score for band %s", band_name)
            end

            -- Check RSSI scoring configuration if present
            if band_cfg.rssi_scoring then
                if not (type(band_cfg.rssi_scoring) == "table") then
                    return string.format("Invalid rssi_scoring type for band %s, should be a table", band_name)
                end

                local required_rssi_fields = {
                    "good_threshold",
                    "good_reward",
                    "bad_threshold",
                    "bad_penalty"
                }
                for _, field in ipairs(required_rssi_fields) do
                    if band_cfg.rssi_scoring[field] == nil then
                        return string.format("Missing rssi_scoring.%s for band %s", field, band_name)
                    end
                end
            end

            -- Check channel utilization configuration if present
            if band_cfg.chan_util_scoring then
                if not (type(band_cfg.chan_util_scoring) == "table") then
                    return string.format("Invalid chan_util_scoring type for band %s, should be a table", band_name)
                end

                local required_chan_fields = {
                    "good_threshold",
                    "good_reward",
                    "bad_threshold",
                    "bad_penalty"
                }
                for _, field in ipairs(required_chan_fields) do
                    if band_cfg.chan_util_scoring[field] == nil then
                        return string.format("Missing chan_util_scoring.%s for band %s", field, band_name)
                    end
                end
            end

            -- Check support bonuses if present
            if band_cfg.support_bonuses and not (type(band_cfg.support_bonuses) == "table") then
                return string.format("Invalid support_bonuses type for band %s, should be a table", band_name)
            end
        end

        return nil
    end

    -- New function to apply band steering configuration
    local function apply_band_steering_config(ctx, conn, band_configs)
        local reqs = {}

        if band_configs.log_level then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_log_level' },
                { band_configs.log_level }
            ))
        end

        -- Configure global settings
        local globals = band_configs.globals or {}
        if globals.kicking then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_kicking' },
                {
                    globals.kicking.kick_mode,
                    globals.kicking.bandwidth_threshold,
                    globals.kicking.kicking_threshold,
                    globals.kicking.evals_before_kick
                }
            ))
        end

        if globals.stations then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_station_counting' },
                {
                    globals.stations.use_station_count,
                    globals.stations.max_station_diff
                }
            ))
        end

        if globals.rrm_mode then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_rrm_mode' },
                { globals.rrm_mode }
            ))
        end

        if globals.neighbor_reports then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_neighbour_reports' },
                {
                    globals.neighbor_reports.dyn_report_num,
                    globals.neighbor_reports.disassoc_report_len
                }
            ))
        end

        if globals.legacy then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_legacy_options' },
                { globals.legacy }
            ))
        end

        -- Configure timing settings
        local timing = band_configs.timings or {}
        if timing.updates then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_update_freq' },
                { timing.updates }
            ))
        end

        if timing.inactive_client_kickoff then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_client_inactive_kickoff' },
                { timing.inactive_client_kickoff }
            ))
        end

        if timing.cleanup then
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_cleanup' },
                { timing.cleanup }
            ))
        end

        -- Configure networking settings
        local networking = band_configs.networking or {}
        if networking.method then
            local network_options = {
                ip = networking.ip,
                port = networking.port,
                broadcast_port = networking.broadcast_port,
                enable_encryption = networking.enable_encryption
            }
            reqs[#reqs + 1] = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'set_networking' },
                { networking.method, network_options }
            ))
        end

        -- Configure band-specific settings
        local bands = band_configs.bands or {}
        for band_name, band_cfg in pairs(bands) do
            -- Set band priority
            if band_cfg.initial_score then
                reqs[#reqs + 1] = conn:request(new_msg(
                    { 'hal', 'capability', 'band', '1', 'control', 'set_band_priority' },
                    { band_name, band_cfg.initial_score }
                ))
            end

            -- Set RSSI scoring
            if band_cfg.rssi_scoring then
                local rssi_options = {
                    rssi_center = band_cfg.rssi_scoring.center,
                    rssi_weight = band_cfg.rssi_scoring.weight,
                    rssi_reward_threshold = band_cfg.rssi_scoring.good_threshold,
                    rssi_reward = band_cfg.rssi_scoring.good_reward,
                    rssi_penalty_threshold = band_cfg.rssi_scoring.bad_threshold,
                    rssi_penalty = band_cfg.rssi_scoring.bad_penalty
                }
                reqs[#reqs + 1] = conn:request(new_msg(
                    { 'hal', 'capability', 'band', '1', 'control', 'set_band_kicking' },
                    { band_name, rssi_options }
                ))
            end

            -- Set channel utilization scoring
            if band_cfg.chan_util_scoring then
                local channel_options = {
                    channel_util_reward_threshold = band_cfg.chan_util_scoring.good_threshold,
                    channel_util_reward = band_cfg.chan_util_scoring.good_reward,
                    channel_util_penalty_threshold = band_cfg.chan_util_scoring.bad_threshold,
                    channel_util_penalty = band_cfg.chan_util_scoring.bad_penalty
                }
                reqs[#reqs + 1] = conn:request(new_msg(
                    { 'hal', 'capability', 'band', '1', 'control', 'set_band_kicking' },
                    { band_name, channel_options }
                ))
            end

            -- Set support bonuses
            if band_cfg.support_bonuses then
                for support_type, bonus in pairs(band_cfg.support_bonuses) do
                    reqs[#reqs + 1] = conn:request(new_msg(
                        { 'hal', 'capability', 'band', '1', 'control', 'set_support_bonus' },
                        { band_name, support_type, bonus }
                    ))
                end
            end
        end

        fiber.spawn(function()
            for _, req in ipairs(reqs) do
                local resp, err = req:next_msg_with_context(ctx)
                req:unsubscribe()
                if err or (resp and resp.payload and resp.payload.err) then
                    log.error(string.format(
                        "%s - %s: Band steering config error: %s",
                        ctx:value("service_name"),
                        ctx:value("fiber_name"),
                        err or resp.payload.err
                    ))
                end
            end

            -- Apply band steering configuration
            local req = conn:request(new_msg(
                { 'hal', 'capability', 'band', '1', 'control', 'apply' }
            ))
            local resp, ctx_err = req:next_msg_with_context(ctx)
            req:unsubscribe()
            if ctx_err or resp and resp.payload and resp.payload.err then
                log.error(string.format(
                    "%s - %s: Band steering apply error: %s",
                    ctx:value("service_name"),
                    ctx:value("fiber_name"),
                    ctx_err or resp.payload.err
                ))
            end
        end)
    end

    local function apply_config(config)
        report_period = config.report_period
        for _, radio_cfg in ipairs(config.radios) do
            local radio = radios[radio_cfg.name]
            if radio then
                radio:apply_config(radio_cfg, report_period)
            end
            radio_configs[radio_cfg.name] = radio_cfg
        end

        local radio_ssids = {}
        for _, ssid_cfg in ipairs(config.ssids) do
            local ssids, err
            ssid_cfg.has_band_steering = config.band_steering and true or false
            if ssid_cfg.mainflux_path then
                local base_cfg = {}
                for k, v in pairs(ssid_cfg) do
                    if k ~= 'mainflux_path' then
                        base_cfg[k] = v
                    end
                end
                ssids, err = utils.parse_mainflux_ssids(ctx, conn, ssid_cfg.mainflux_path, base_cfg)
                if err then
                    log.error(string.format(
                        "%s - %s: SSID %s mainflux config error: %s",
                        ctx:value("service_name"),
                        ctx:value("fiber_name"),
                        ssid_cfg.name or "(unknown)",
                        err
                    ))
                    ssids = {}
                end
            end
            -- a mainflux path may spawn multiple ssids from one ssid_cfg
            for _, ssid in ipairs(ssids or { ssid_cfg }) do
                for _, radio_id in ipairs(ssid.radios) do
                    if radio_ssids[radio_id] then
                        table.insert(radio_ssids[radio_id], ssid)
                    else
                        radio_ssids[radio_id] = { ssid }
                    end
                end
            end
        end
        ssid_configs = radio_ssids
        for radio_id, ssids in pairs(ssid_configs) do
            local radio = radios[radio_id]
            if radio then
                radio:remove_ssids()
                radio:apply_ssids(ssids)
            end
        end

        -- Configure band steering if it exists
        if config.band_steering then
            apply_band_steering_config(ctx, conn, config.band_steering)
        end
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

function wifi_service:start(ctx, conn)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    service.spawn_fiber('Radio Listener', conn, ctx, function(fctx)
        radio_listener(fctx, conn)
    end)
    service.spawn_fiber('Radio Manager', conn, ctx, function(fctx)
        radio_manager(fctx, conn)
    end)
end

return wifi_service
