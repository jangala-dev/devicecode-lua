-- services/wifi.lua
--
-- Wifi service: forwards radio/band configs to HAL capabilities,
-- manages SSIDs, subscribes to radio stats, handles MAC session tracking.

local fibers = require "fibers"

local perform = fibers.perform

local base    = require 'devicecode.service_base'
local cap_sdk = require 'services.hal.sdk.cap'
local gen     = require 'services.wifi.gen'
local utils   = require 'services.wifi.utils'

------------------------------------------------------------------------
-- Config types (annotation-only)
------------------------------------------------------------------------

---@class WifiRadioConfig
---@field name string          UCI radio section name (e.g. "radio0")
---@field band RadioBand
---@field channel number|string
---@field htmode RadioHtmode
---@field channels? (number|string)[]  required when channel == 'auto'
---@field txpower? number|string
---@field country? string      ISO-3166-1 alpha-2 country code
---@field disabled? boolean
---@field report_period? number  seconds between stats reports

---@class WifiSsidConfig
---@field name? string         SSID / network name
---@field mode string          access_point | client | adhoc | mesh | monitor
---@field encryption? RadioEncryption
---@field password? string
---@field network? string      UCI network interface name
---@field radios string[]      radio section names this SSID should be added to
---@field mainflux_path? string  path in the configs filesystem cap

---@class WifiBandSteeringConfig
---@field globals? table        global band-steering tunables
---@field timings? table        timing / threshold tunables
---@field bands? table          per-band scoring configuration

---@class WifiServiceData
---@field schema string
---@field report_period? number
---@field radios WifiRadioConfig[]
---@field ssids WifiSsidConfig[]
---@field band_steering? WifiBandSteeringConfig

---@class WifiServiceOpts
---@field name? string
---@field env? table

-- Mode names the config uses vs what the radio driver expects
local MODE_MAP = {
    access_point = 'ap',
    client       = 'sta',
}

local function map_mode(mode)
    return MODE_MAP[mode] or mode
end

local function is_table(v) return type(v) == 'table' end

------------------------------------------------------------------------
-- Band steering application
------------------------------------------------------------------------

-- Remap tables for config-level scoring keys → band driver option keys
local RSSI_SCORING_REMAP = {
    center         = 'rssi_center',
    weight         = 'rssi_weight',
    good_threshold = 'rssi_reward_threshold',
    good_reward    = 'rssi_reward',
    bad_threshold  = 'rssi_penalty_threshold',
    bad_penalty    = 'rssi_penalty',
}
local CHAN_UTIL_SCORING_REMAP = {
    good_threshold = 'channel_util_reward_threshold',
    good_reward    = 'channel_util_reward',
    bad_threshold  = 'channel_util_penalty_threshold',
    bad_penalty    = 'channel_util_penalty',
}

local function remap_keys(src, mapping)
    local out = {}
    for src_key, dst_key in pairs(mapping) do
        if src[src_key] ~= nil then out[dst_key] = src[src_key] end
    end
    return out
end

---@param band_cap CapabilityReference
---@param band_cfg WifiBandSteeringConfig
---@param svc ServiceBase
local function apply_band_steering(band_cap, band_cfg, svc)
    if not is_table(band_cfg) then return end
    local globals  = band_cfg.globals  or {}
    local timings  = band_cfg.timings  or {}
    local bands    = band_cfg.bands    or {}

    local function rpc(method, args, opts)
        local reply, err = perform(band_cap:call_control_op(method, args, opts))
        if err and err ~= "" then
            svc:obs_log('warn', { what = 'band_rpc_failed', method = method, err = tostring(err) })
            return false
        end
        if not reply or reply.ok ~= true then
            svc:obs_log('warn', { what = 'band_rpc_error', method = method,
                                   reason = reply and reply.reason or 'nil' })
            return false
        end
        return true
    end

    local slow = { timeout = 10.0 }

    svc:obs_log('debug', { what = 'band_config_start' })
    rpc('clear', {}, slow)

    -- kicking
    local kicking = globals.kicking
    if is_table(kicking) then
        local args, err = cap_sdk.args.new.BandSetKickingOpts(
            kicking.kick_mode        or 'none',
            kicking.bandwidth_threshold or 0,
            kicking.kicking_threshold   or 0,
            kicking.evals_before_kick   or 0)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_kicking', err = err })
        else
            rpc('set_kicking', args)
        end
    end

    -- station counting
    if is_table(globals.stations) then
        local st = globals.stations
        local args, err = cap_sdk.args.new.BandSetStationCountingOpts(
            st.use_station_count or false,
            st.max_station_diff  or 0)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_station_counting', err = err })
        else
            rpc('set_station_counting', args)
        end
    end

    -- rrm_mode
    if globals.rrm_mode then
        local args, err = cap_sdk.args.new.BandSetRrmModeOpts(globals.rrm_mode)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_rrm_mode', err = err })
        else
            rpc('set_rrm_mode', args)
        end
    end

    -- neighbour reports
    if is_table(globals.neighbor_reports) then
        local nr = globals.neighbor_reports
        local args, err = cap_sdk.args.new.BandSetNeighbourReportsOpts(
            nr.dyn_report_num      or 0,
            nr.disassoc_report_len or 0)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_neighbour_reports', err = err })
        else
            rpc('set_neighbour_reports', args)
        end
    end

    -- legacy options
    if is_table(globals.legacy) then
        local args, err = cap_sdk.args.new.BandSetLegacyOptionsOpts(globals.legacy)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_legacy_options', err = err })
        else
            rpc('set_legacy_options', args)
        end
    end

    -- update frequencies
    if is_table(timings.updates) then
        local args, err = cap_sdk.args.new.BandSetUpdateFreqOpts(timings.updates)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_update_freq', err = err })
        else
            rpc('set_update_freq', args)
        end
    end

    -- inactive client kickoff
    if timings.inactive_client_kickoff ~= nil then
        local args, err = cap_sdk.args.new.BandSetClientInactiveKickoffOpts(timings.inactive_client_kickoff)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_client_inactive_kickoff', err = err })
        else
            rpc('set_client_inactive_kickoff', args)
        end
    end

    -- cleanup timeouts
    if is_table(timings.cleanup) then
        local args, err = cap_sdk.args.new.BandSetCleanupOpts(timings.cleanup)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_cleanup', err = err })
        else
            rpc('set_cleanup', args)
        end
    end

    -- per-band settings
    for band_key, band_data in pairs(bands) do
        if is_table(band_data) then
            if band_data.initial_score ~= nil then
                local args, err = cap_sdk.args.new.BandSetBandPriorityOpts(band_key, band_data.initial_score)
                if not args then
                    svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_band_priority', err = err })
                else
                    rpc('set_band_priority', args)
                end
            end
            if is_table(band_data.rssi_scoring) then
                local args, err = cap_sdk.args.new.BandSetBandKickingOpts(
                    band_key, remap_keys(band_data.rssi_scoring, RSSI_SCORING_REMAP))
                if not args then
                    svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_band_kicking', err = err })
                else
                    rpc('set_band_kicking', args)
                end
            end
            if is_table(band_data.chan_util_scoring) then
                local args, err = cap_sdk.args.new.BandSetBandKickingOpts(
                    band_key, remap_keys(band_data.chan_util_scoring, CHAN_UTIL_SCORING_REMAP))
                if not args then
                    svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_band_kicking', err = err })
                else
                    rpc('set_band_kicking', args)
                end
            end
            if is_table(band_data.support_bonuses) then
                for support_key, reward in pairs(band_data.support_bonuses) do
                    local args, err = cap_sdk.args.new.BandSetSupportBonusOpts(band_key, support_key, reward)
                    if not args then
                        svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_support_bonus', err = err })
                    else
                        rpc('set_support_bonus', args)
                    end
                end
            end
        end
    end

    rpc('apply', {}, slow)
    svc:obs_log('info', { what = 'band_config_applied' })
end

------------------------------------------------------------------------
-- Radio configuration sequence
------------------------------------------------------------------------

---@param radio_cap CapabilityReference
---@param radio_cfg WifiRadioConfig
---@param ssid_cfgs WifiSsidConfig[]
---@param fs_configs_cap CapabilityReference?
---@param band_steering_cfg WifiBandSteeringConfig?
---@param svc ServiceBase
local function apply_radio_config(radio_cap, radio_cfg, ssid_cfgs, fs_configs_cap, band_steering_cfg, svc)
    local radio_id = radio_cap.id

    local function rpc(method, args)
        local reply, err = radio_cap:call_control(method, args)
        if err and err ~= "" then
            svc:obs_log('warn', { what = 'radio_rpc_failed', radio = radio_id,
                                   method = method, err = tostring(err) })
            return false
        end
        if not reply or reply.ok ~= true then
            svc:obs_log('warn', { what = 'radio_rpc_error', radio = radio_id,
                                   method = method, reason = reply and reply.reason or 'nil' })
            return false
        end
        return true, reply
    end

    svc:obs_log('debug', { what = 'radio_config_start', radio = radio_id })

    -- 1. Clear staged config
    if not rpc('clear_radio_config', {}) then return end

    -- 2. Set report period
    do
        local args, err = cap_sdk.args.new.RadioSetReportPeriodOpts(radio_cfg.report_period or 60)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_report_period', err = err })
            return
        end
        if not rpc('set_report_period', args) then return end
    end

    -- 3. Set channels
    do
        local args, err = cap_sdk.args.new.RadioSetChannelsOpts(
            radio_cfg.band, radio_cfg.channel, radio_cfg.htmode, radio_cfg.channels)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_channels', err = err })
            return
        end
        if not rpc('set_channels', args) then return end
        svc:obs_log('debug', { what = 'radio_channels_set', radio = radio_id,
            band = radio_cfg.band, channel = radio_cfg.channel, htmode = radio_cfg.htmode })
    end

    -- 4. txpower (optional)
    if radio_cfg.txpower ~= nil then
        local args, err = cap_sdk.args.new.RadioSetTxpowerOpts(radio_cfg.txpower)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_txpower', err = err })
        else
            rpc('set_txpower', args)
        end
    end

    -- 5. country (optional)
    if radio_cfg.country then
        local args, err = cap_sdk.args.new.RadioSetCountryOpts(radio_cfg.country)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_country', err = err })
        else
            rpc('set_country', args)
        end
    end

    -- 6. enabled / disabled (optional)
    if radio_cfg.disabled ~= nil then
        local args, err = cap_sdk.args.new.RadioSetEnabledOpts(not radio_cfg.disabled)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_enabled', err = err })
        else
            rpc('set_enabled', args)
        end
    end

    -- Determine enable_steering from band steering kick_mode
    local kick_mode = band_steering_cfg
        and is_table(band_steering_cfg.globals)
        and is_table(band_steering_cfg.globals.kicking)
        and band_steering_cfg.globals.kicking.kick_mode
    local enable_steering = kick_mode and kick_mode ~= 'none' or false

    -- 7. Add interfaces per SSID
    for _, ssid_cfg in ipairs(ssid_cfgs) do
        repeat
            -- Check if this SSID applies to this radio
            local applies = false
            if is_table(ssid_cfg.radios) then
                for _, r in ipairs(ssid_cfg.radios) do
                    if r == radio_cap.id then applies = true; break end
                end
            end
            if not applies then break end

            if ssid_cfg.mainflux_path then
                -- Source credentials from filesystem cap; strict: skip on failure
                if not fs_configs_cap then
                    svc:obs_log('warn', { what = 'no_fs_configs_cap', ssid = ssid_cfg.name })
                    break
                end
                local base_cfg = {
                    network    = ssid_cfg.network,
                    encryption = ssid_cfg.encryption or 'none',
                    password   = ssid_cfg.password   or '',
                    mode       = map_mode(ssid_cfg.mode or 'access_point'),
                }
                local ssids, serr = utils.parse_mainflux_ssids(fs_configs_cap, ssid_cfg.mainflux_path, base_cfg)
                if not ssids then
                    svc:obs_log('warn', { what = 'mainflux_ssid_failed', ssid = ssid_cfg.name, err = serr })
                    break
                end
                for _, mssd in ipairs(ssids) do
                    local args, err = cap_sdk.args.new.RadioAddInterfaceOpts(
                        mssd.name or mssd.ssid or '',
                        mssd.encryption or 'none',
                        mssd.password or '',
                        mssd.network or '',
                        map_mode(mssd.mode or 'ap'),
                        enable_steering)
                    if not args then
                        svc:obs_log('warn', { what = 'radio_args_invalid', method = 'add_interface', err = err })
                    else
                        local ok, reply = rpc('add_interface', args)
                        if ok then
                            svc:obs_log('debug', { what = 'radio_iface_added', radio = radio_id,
                                ssid = mssd.name or mssd.ssid, network = mssd.network,
                                iface = reply and reply.reason or nil })
                        end
                    end
                end
            else
                -- Direct SSID from config
                local args, err = cap_sdk.args.new.RadioAddInterfaceOpts(
                    ssid_cfg.name or '',
                    ssid_cfg.encryption or 'none',
                    ssid_cfg.password or '',
                    ssid_cfg.network or '',
                    map_mode(ssid_cfg.mode or 'access_point'),
                    enable_steering)
                if not args then
                    svc:obs_log('warn', { what = 'radio_args_invalid', method = 'add_interface', err = err })
                else
                    local ok, reply = rpc('add_interface', args)
                    if ok then
                        svc:obs_log('debug', { what = 'radio_iface_added', radio = radio_id,
                            ssid = ssid_cfg.name, network = ssid_cfg.network,
                            iface = reply and reply.reason or nil })
                    end
                end
            end
        until true
    end

    -- 8. Apply
    if not rpc('apply', {}) then return end
    svc:obs_log('info', { what = 'radio_config_applied', radio = radio_id })
end

------------------------------------------------------------------------
-- Per-radio stats and session forwarding loop
------------------------------------------------------------------------

---@param conn Connection
---@param id string
---@param radio_cfg WifiRadioConfig?
---@param svc ServiceBase
local function radio_stats_loop(conn, id, radio_cfg, svc)
    -- Sessions: mac → session_id (raw MAC as key)
    local sessions = {}

    -- Per-interface and per-radio station counts
    local iface_sta = {}  -- iface_name → count
    local radio_sta = 0

    -- Band digit for metric topics: "2g" → "2", "5g" → "5"
    local band        = ((radio_cfg and radio_cfg.band) or ''):sub(1, 1)
    local hw_platform = '1'

    -- Parse interface index from generated name suffix (e.g. "radio0_i2" → "2")
    local function iface_idx(name)
        local n = name and name:match('_i(%d+)$')
        return n or '0'
    end

    local state_sub = conn:subscribe({ 'cap', 'radio', id, 'state', '+' })
    local event_sub = conn:subscribe({ 'cap', 'radio', id, 'event', '+' })

    fibers.current_scope():finally(function()
        state_sub:unsubscribe()
        event_sub:unsubscribe()
    end)

    while true do
        local which, msg = perform(fibers.named_choice({
            state  = state_sub:recv_op(),
            event  = event_sub:recv_op(),
            cancel = fibers.current_scope():cancel_op(),
        }))

        if which == 'cancel' then break end

        if not msg then
            svc:obs_log('debug', { what = 'radio_sub_closed', radio = id })
            break
        end

        if which == 'state' then
            local key = msg.topic and msg.topic[5]
            local p   = msg.payload
            if key and is_table(p) then
                local rd  = 'rd' .. band
                local idx = iface_idx(p.interface)
                if key == 'iface_txpower' then
                    conn:publish({'wifi','hp',hw_platform,rd,idx,'power'}, p.value)
                elseif key == 'iface_channel' then
                    conn:publish({'wifi','hp',hw_platform,rd,idx,'channel'}, p.channel)
                elseif key == 'iface_noise' then
                    conn:publish({'wifi','hp',hw_platform,rd,idx,'noise'}, p.value)
                elseif key == 'iface_rx_bytes'    or key == 'iface_tx_bytes'
                    or key == 'iface_rx_packets'  or key == 'iface_tx_packets'
                    or key == 'iface_rx_dropped'  or key == 'iface_tx_dropped'
                    or key == 'iface_rx_errors'   or key == 'iface_tx_errors' then
                    -- Strip "iface_" prefix (6 chars) to get the metric name
                    conn:publish({'wifi','hp',hw_platform,rd,idx, key:sub(7)}, p.value)
                elseif key == 'client_signal' then
                    local uid = gen.userid(p.mac)
                    local sid = sessions[p.mac]
                    if sid then
                        conn:publish({'wifi','clients',uid,'sessions',sid,'signal'}, p.signal)
                    end
                elseif key == 'client_tx_bytes' or key == 'client_rx_bytes' then
                    -- Strip "client_" prefix (7 chars) to get tx_bytes / rx_bytes
                    local uid = gen.userid(p.mac)
                    local sid = sessions[p.mac]
                    if sid then
                        conn:publish({'wifi','clients',uid,'sessions',sid, key:sub(8)}, p.value)
                    end
                end
            end

        elseif which == 'event' then
            local event_name = msg.topic and msg.topic[5]

            if event_name == 'client_event' then
                local p = msg.payload
                if is_table(p) and p.mac then
                    local mac       = p.mac
                    local iface     = p.interface
                    local connected = p.connected
                    local timestamp = p.timestamp or os.time()
                    local uid       = gen.userid(mac)
                    local change    = connected and 1 or -1

                    -- Update per-interface and per-radio station counts
                    iface_sta[iface] = math.max(0, (iface_sta[iface] or 0) + change)
                    radio_sta        = math.max(0, radio_sta + change)

                    local rd  = 'rd' .. band
                    local idx = iface_idx(iface)
                    conn:publish({'wifi','hp',hw_platform,rd,idx,'num_sta'}, iface_sta[iface])
                    conn:publish({'wifi','hp',hw_platform,'num_sta'}, radio_sta)

                    -- Session tracking + session event publish
                    if connected then
                        local sid = gen.gen_session_id()
                        sessions[mac] = sid
                        conn:publish({'wifi','clients',uid,'sessions',sid,'session_start'}, timestamp)
                    else
                        local sid = sessions[mac]
                        if sid then
                            conn:publish({'wifi','clients',uid,'sessions',sid,'session_end'}, timestamp)
                            sessions[mac] = nil
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Service entry point
------------------------------------------------------------------------

local WifiService = {}

---@param conn Connection
---@param opts? WifiServiceOpts
function WifiService.start(conn, opts)
    local svc = base.new(conn, { name = opts and opts.name or 'wifi', env = opts and opts.env })

    svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
    svc:obs_log('info', 'service start() entered')
    svc:status('starting')
    svc:spawn_heartbeat(10, 'tick')

    local parent_scope = fibers.current_scope()

    parent_scope:finally(function()
        local scope = fibers.current_scope()
        local st, primary = scope:status()
        if st == 'failed' then
            svc:obs_log('error', { what = 'scope_failed', err = tostring(primary) })
        end
        svc:status('stopped', primary and { reason = tostring(primary) } or nil)
        svc:obs_log('info', 'service stopped')
    end)

    -- Current service state
    ---@type any
    local current_data   = nil   -- data field of last valid config
    local last_rev       = -1
    local fs_configs_cap = nil   -- configs filesystem cap reference
    local band_cap       = nil   -- band capability reference
    local radio_scopes   = {}    -- radio_id → child scope

    -- Subscribe to config topic
    local cfg_sub = conn:subscribe({ 'cfg', 'wifi' })

    -- Subscribe to cap state notifications (radio, band, fs/configs)
    local radio_cap_listener = cap_sdk.new_cap_listener(conn, 'radio', '+')
    local band_cap_listener  = cap_sdk.new_cap_listener(conn, 'band',  '1')
    local fs_cap_listener    = cap_sdk.new_cap_listener(conn, 'fs',    'configs')

    local function get_radio_cfg(radio_id)
        if not is_table(current_data) or not is_table(current_data.radios) then
            return nil
        end
        for _, r in ipairs(current_data.radios) do
            if r.name == radio_id then return r end
        end
        return nil
    end

    local function configure_radio(id)
        local radio_cfg = get_radio_cfg(id)
        if not radio_cfg then
            svc:obs_log('debug', { what = 'no_config_for_radio', radio = id })
            return
        end
        local cap = cap_sdk.new_cap_ref(conn, 'radio', id)
        local ssids = is_table(current_data.ssids) and current_data.ssids or {}
        apply_radio_config(cap, radio_cfg, ssids, fs_configs_cap,
            is_table(current_data) and current_data.band_steering or nil, svc)
    end

    local function spawn_radio_scope(id)
        -- Cancel existing scope if any
        if radio_scopes[id] then
            radio_scopes[id]:cancel('reconfigure')
            radio_scopes[id] = nil
        end

        local scope, serr = parent_scope:child()
        if not scope then
            svc:obs_log('error', { what = 'radio_scope_failed', radio = id, err = serr })
            return
        end
        radio_scopes[id] = scope

        scope:spawn(function()
            -- Apply configuration for this radio
            configure_radio(id)
            -- Capture radio_cfg after configure so band is available for metric topics
            local radio_cfg = get_radio_cfg(id)
            -- Run stats forwarding loop
            radio_stats_loop(conn, id, radio_cfg, svc)
        end)
    end

    local function remove_radio(id)
        if radio_scopes[id] then
            radio_scopes[id]:cancel('radio removed')
            radio_scopes[id] = nil
        end
    end

    local function apply_band_config()
        if band_cap and is_table(current_data) and is_table(current_data.band_steering) then
            apply_band_steering(band_cap, current_data.band_steering, svc)
        end
    end

    local function reapply_all_radios()
        for id in pairs(radio_scopes) do
            spawn_radio_scope(id)
        end
    end

    svc:status('running')
    svc:obs_log('info', 'service running')

    -- Aggregate global wifi/num_sta across all radios.
    -- Each radio also publishes wifi/hp/<platform>/num_sta for its own total.
    parent_scope:spawn(function()
        local global_sta = 0
        local global_event_sub = conn:subscribe({ 'cap', 'radio', '+', 'event', 'client_event' })
        fibers.current_scope():finally(function()
            global_event_sub:unsubscribe()
        end)
        while true do
            local which, msg = perform(fibers.named_choice({
                event  = global_event_sub:recv_op(),
                cancel = parent_scope:cancel_op(),
            }))
            if which == 'cancel' then break end
            if msg and is_table(msg.payload) and msg.payload.mac then
                local change = msg.payload.connected and 1 or -1
                global_sta = math.max(0, global_sta + change)
                conn:publish({ 'wifi', 'num_sta' }, global_sta)
            end
        end
    end)

    while true do
        local choices = {
            cfg    = cfg_sub:recv_op(),
            radio  = radio_cap_listener.sub:recv_op(),
            band   = band_cap_listener.sub:recv_op(),
            fs     = fs_cap_listener.sub:recv_op(),
            cancel = parent_scope:cancel_op(),
        }

        local which, msg = perform(fibers.named_choice(choices))

        if which == 'cancel' then break end

        if not msg then
            svc:obs_log('debug', { what = 'subscription_closed', source = which })
            -- A closed subscription is non-fatal; continue
        elseif which == 'cfg' then
            local payload = msg.payload
            if not is_table(payload) then
                svc:obs_log('warn', { what = 'invalid_config_payload' })
            else
                local rev  = payload.rev
                local data = payload.data
                if type(rev) == 'number' and rev <= last_rev then
                    svc:obs_log('debug', { what = 'stale_config', rev = rev, last_rev = last_rev })
                elseif not is_table(data) then
                    svc:obs_log('warn', { what = 'config_data_not_table' })
                else
                    last_rev     = rev or last_rev
                    current_data = data
                    svc:obs_event('config_applied', { rev = rev })

                    -- Re-apply config to all existing radios and band
                    reapply_all_radios()
                    apply_band_config()
                end
            end

        elseif which == 'radio' then
            local id    = msg.topic and msg.topic[3]
            local state = msg.payload
            if state == 'added' then
                svc:obs_log('info', { what = 'radio_cap_added', radio = id })
                spawn_radio_scope(id)
            elseif state == 'removed' then
                svc:obs_log('info', { what = 'radio_cap_removed', radio = id })
                remove_radio(id)
            end

        elseif which == 'band' then
            local state = msg.payload
            if state == 'added' then
                svc:obs_log('info', { what = 'band_cap_added' })
                band_cap = cap_sdk.new_cap_ref(conn, 'band', '1')
                apply_band_config()
            elseif state == 'removed' then
                svc:obs_log('info', { what = 'band_cap_removed' })
                band_cap = nil
            end

        elseif which == 'fs' then
            local state = msg.payload
            if state == 'added' then
                svc:obs_log('info', { what = 'fs_configs_cap_added' })
                fs_configs_cap = cap_sdk.new_cap_ref(conn, 'fs', 'configs')
                -- Re-apply radios since SSIDs may need the fs cap
                reapply_all_radios()
            elseif state == 'removed' then
                svc:obs_log('info', { what = 'fs_configs_cap_removed' })
                fs_configs_cap = nil
            end
        end
    end

    -- Cleanup all radio scopes on exit
    for id, scope in pairs(radio_scopes) do
        scope:cancel('service stopping')
        radio_scopes[id] = nil
    end

    cfg_sub:unsubscribe()
    radio_cap_listener:close()
    band_cap_listener:close()
    fs_cap_listener:close()
end

return WifiService
