-- services/wifi.lua
--
-- Wifi service: forwards radio/band configs to HAL capabilities,
-- manages SSIDs, subscribes to radio stats, handles MAC session tracking.
--
-- Structure:
--   Constants / helpers
--   band_rpc / apply_band_steering
--   radio_rpc / apply_radio_config
--   on_radio_state / on_radio_event / radio_stats_loop
--   run_global_num_sta
--   Service context helpers  (get_radio_cfg … reapply_all_radios)
--   Main-loop handlers       (on_cfg … on_fs_cap)
--   WifiService.start

local fibers   = require "fibers"

local perform  = fibers.perform

local base     = require 'devicecode.service_base'
local cap_sdk  = require 'services.hal.sdk.cap'
local gen      = require 'services.wifi.gen'
local utils    = require 'services.wifi.utils'

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

-- Parse interface index from generated name suffix (e.g. "radio0_i2" → "2")
local function iface_idx(name)
    return (name and name:match('_i(%d+)$')) or '0'
end

---@param key string
---@return Topic
local function t_obs_metric(key) return { 'obs', 'v1', 'wifi', 'metric', key } end

---@param key string
---@return Topic
local function t_obs_event(key) return { 'obs', 'v1', 'wifi', 'event', key } end

------------------------------------------------------------------------
-- Band steering RPC helper
------------------------------------------------------------------------

local function band_rpc(band_cap, svc, method, args, opts)
    local reply, err = perform(band_cap:call_control_op(method, args, opts))
    if err and err ~= "" then
        svc:obs_log('warn', { what = 'band_rpc_failed', method = method, err = tostring(err) })
        return false
    end
    if not reply or reply.ok ~= true then
        svc:obs_log('warn', {
            what   = 'band_rpc_error',
            method = method,
            reason = reply and reply.reason or 'nil',
        })
        return false
    end
    return true
end

---@param band_cap CapabilityReference
---@param band_cfg WifiBandSteeringConfig
---@param svc ServiceBase
local function apply_band_steering(band_cap, band_cfg, svc)
    if not is_table(band_cfg) then return end
    local globals = band_cfg.globals or {}
    local timings = band_cfg.timings or {}
    local bands   = band_cfg.bands or {}

    local slow    = { timeout = 10.0 }

    svc:obs_log('debug', { what = 'band_config_start' })
    band_rpc(band_cap, svc, 'clear', {}, slow)

    -- kicking
    local kicking = globals.kicking
    if is_table(kicking) then
        local args, err = cap_sdk.args.new.BandSetKickingOpts(
            kicking.kick_mode or 'none',
            kicking.bandwidth_threshold or 0,
            kicking.kicking_threshold or 0,
            kicking.evals_before_kick or 0)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_kicking', err = err })
        else
            band_rpc(band_cap, svc, 'set_kicking', args)
        end
    end

    -- station counting
    if is_table(globals.stations) then
        local st = globals.stations
        local args, err = cap_sdk.args.new.BandSetStationCountingOpts(
            st.use_station_count or false,
            st.max_station_diff or 0)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_station_counting', err = err })
        else
            band_rpc(band_cap, svc, 'set_station_counting', args)
        end
    end

    -- rrm_mode
    if globals.rrm_mode then
        local args, err = cap_sdk.args.new.BandSetRrmModeOpts(globals.rrm_mode)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_rrm_mode', err = err })
        else
            band_rpc(band_cap, svc, 'set_rrm_mode', args)
        end
    end

    -- neighbour reports
    if is_table(globals.neighbor_reports) then
        local nr = globals.neighbor_reports
        local args, err = cap_sdk.args.new.BandSetNeighbourReportsOpts(
            nr.dyn_report_num or 0,
            nr.disassoc_report_len or 0)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_neighbour_reports', err = err })
        else
            band_rpc(band_cap, svc, 'set_neighbour_reports', args)
        end
    end

    -- legacy options
    if is_table(globals.legacy) then
        local args, err = cap_sdk.args.new.BandSetLegacyOptionsOpts(globals.legacy)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_legacy_options', err = err })
        else
            band_rpc(band_cap, svc, 'set_legacy_options', args)
        end
    end

    -- update frequencies
    if is_table(timings.updates) then
        local args, err = cap_sdk.args.new.BandSetUpdateFreqOpts(timings.updates)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_update_freq', err = err })
        else
            band_rpc(band_cap, svc, 'set_update_freq', args)
        end
    end

    -- inactive client kickoff
    if timings.inactive_client_kickoff ~= nil then
        local args, err = cap_sdk.args.new.BandSetClientInactiveKickoffOpts(timings.inactive_client_kickoff)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_client_inactive_kickoff', err = err })
        else
            band_rpc(band_cap, svc, 'set_client_inactive_kickoff', args)
        end
    end

    -- cleanup timeouts
    if is_table(timings.cleanup) then
        local args, err = cap_sdk.args.new.BandSetCleanupOpts(timings.cleanup)
        if not args then
            svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_cleanup', err = err })
        else
            band_rpc(band_cap, svc, 'set_cleanup', args)
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
                    band_rpc(band_cap, svc, 'set_band_priority', args)
                end
            end
            if is_table(band_data.rssi_scoring) then
                local args, err = cap_sdk.args.new.BandSetBandKickingOpts(
                    band_key, remap_keys(band_data.rssi_scoring, RSSI_SCORING_REMAP))
                if not args then
                    svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_band_kicking', err = err })
                else
                    band_rpc(band_cap, svc, 'set_band_kicking', args)
                end
            end
            if is_table(band_data.chan_util_scoring) then
                local args, err = cap_sdk.args.new.BandSetBandKickingOpts(
                    band_key, remap_keys(band_data.chan_util_scoring, CHAN_UTIL_SCORING_REMAP))
                if not args then
                    svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_band_kicking', err = err })
                else
                    band_rpc(band_cap, svc, 'set_band_kicking', args)
                end
            end
            if is_table(band_data.support_bonuses) then
                for support_key, reward in pairs(band_data.support_bonuses) do
                    local args, err = cap_sdk.args.new.BandSetSupportBonusOpts(band_key, support_key, reward)
                    if not args then
                        svc:obs_log('warn', { what = 'band_args_invalid', method = 'set_support_bonus', err = err })
                    else
                        band_rpc(band_cap, svc, 'set_support_bonus', args)
                    end
                end
            end
        end
    end

    band_rpc(band_cap, svc, 'apply', {}, slow)
    svc:obs_log('info', { what = 'band_config_applied' })
end

------------------------------------------------------------------------
-- Radio configuration RPC helper
------------------------------------------------------------------------

local function radio_rpc(radio_cap, radio_id, svc, method, args)
    local reply, err = radio_cap:call_control(method, args)
    if err and err ~= "" then
        svc:obs_log('warn', {
            what   = 'radio_rpc_failed',
            radio  = radio_id,
            method = method,
            err    = tostring(err),
        })
        return false
    end
    if not reply or reply.ok ~= true then
        svc:obs_log('warn', {
            what   = 'radio_rpc_error',
            radio  = radio_id,
            method = method,
            reason = reply and reply.reason or 'nil',
        })
        return false
    end
    return true, reply
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

    svc:obs_log('debug', { what = 'radio_config_start', radio = radio_id })

    -- 1. Clear staged config
    if not radio_rpc(radio_cap, radio_id, svc, 'clear_radio_config', {}) then return end

    -- 2. Set report period
    do
        local args, err = cap_sdk.args.new.RadioSetReportPeriodOpts(radio_cfg.report_period or 60)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_report_period', err = err })
            return
        end
        if not radio_rpc(radio_cap, radio_id, svc, 'set_report_period', args) then return end
    end

    -- 3. Set channels
    do
        local args, err = cap_sdk.args.new.RadioSetChannelsOpts(
            radio_cfg.band, radio_cfg.channel, radio_cfg.htmode, radio_cfg.channels)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_channels', err = err })
            return
        end
        if not radio_rpc(radio_cap, radio_id, svc, 'set_channels', args) then return end
        svc:obs_log('debug', {
            what    = 'radio_channels_set',
            radio   = radio_id,
            band    = radio_cfg.band,
            channel = radio_cfg.channel,
            htmode  = radio_cfg.htmode,
        })
    end

    -- 4. txpower (optional)
    if radio_cfg.txpower ~= nil then
        local args, err = cap_sdk.args.new.RadioSetTxpowerOpts(radio_cfg.txpower)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_txpower', err = err })
        else
            radio_rpc(radio_cap, radio_id, svc, 'set_txpower', args)
        end
    end

    -- 5. country (optional)
    if radio_cfg.country then
        local args, err = cap_sdk.args.new.RadioSetCountryOpts(radio_cfg.country)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_country', err = err })
        else
            radio_rpc(radio_cap, radio_id, svc, 'set_country', args)
        end
    end

    -- 6. enabled / disabled (optional)
    if radio_cfg.disabled ~= nil then
        local args, err = cap_sdk.args.new.RadioSetEnabledOpts(not radio_cfg.disabled)
        if not args then
            svc:obs_log('warn', { what = 'radio_args_invalid', method = 'set_enabled', err = err })
        else
            radio_rpc(radio_cap, radio_id, svc, 'set_enabled', args)
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
                    if r == radio_cap.id then
                        applies = true; break
                    end
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
                    password   = ssid_cfg.password or '',
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
                        local ok, reply = radio_rpc(radio_cap, radio_id, svc, 'add_interface', args)
                        if ok then
                            svc:obs_log('debug', {
                                what    = 'radio_iface_added',
                                radio   = radio_id,
                                ssid    = mssd.name or mssd.ssid,
                                network = mssd.network,
                                iface   = reply and reply.reason or nil,
                            })
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
                    local ok, reply = radio_rpc(radio_cap, radio_id, svc, 'add_interface', args)
                    if ok then
                        svc:obs_log('debug', {
                            what    = 'radio_iface_added',
                            radio   = radio_id,
                            ssid    = ssid_cfg.name,
                            network = ssid_cfg.network,
                            iface   = reply and reply.reason or nil,
                        })
                    end
                end
            end
        until true
    end

    -- 8. Apply
    if not radio_rpc(radio_cap, radio_id, svc, 'apply', {}) then return end
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
    local band        = ((radio_cfg and radio_cfg.band) or ''):sub(1, 1)
    local hw_platform = '1'
    local sessions    = {}
    local iface_sta   = {}
    local radio_sta   = 0

    local function on_radio_state(msg)
        local key = msg.topic and msg.topic[5]
        local p   = msg.payload
        if not (key and is_table(p)) then return end

        local prefix, stat = key:match('^(iface)_(.+)$')
        if prefix then
            local idx = iface_idx(p.interface)
            conn:retain(t_obs_metric(stat), {
                value     = p.value,
                namespace = { 'wifi', 'hp', hw_platform, 'rd' .. band, idx, stat },
            })
            return
        end

        prefix, stat = key:match('^(client)_(.+)$')
        if prefix then
            local uid = gen.userid(p.mac)
            local sid = sessions[p.mac]
            if sid then
                conn:retain(t_obs_metric(stat), {
                    value     = p.value,
                    namespace = { 'wifi', 'clients', uid, 'sessions', sid, stat },
                })
            end
        end
    end

    local function on_radio_event(msg)
        local event_name = msg.topic and msg.topic[5]
        if event_name ~= 'client_event' then return end

        local p = msg.payload
        if not (is_table(p) and p.mac) then return end

        local mac        = p.mac
        local iface      = p.interface
        local connected  = p.connected
        local timestamp  = p.timestamp or os.time()
        local uid        = gen.userid(mac)
        local change     = connected and 1 or -1

        iface_sta[iface] = math.max(0, (iface_sta[iface] or 0) + change)
        radio_sta        = math.max(0, radio_sta + change)

        local idx        = iface_idx(iface)
        conn:retain(t_obs_metric('num_sta'), {
            value     = iface_sta[iface],
            namespace = { 'wifi', 'hp', hw_platform, 'rd' .. band, idx, 'num_sta' },
        })
        conn:retain(t_obs_metric('num_sta'), {
            value     = radio_sta,
            namespace = { 'wifi', 'hp', hw_platform, 'rd' .. band, 'num_sta' },
        })

        if connected then
            local sid = gen.gen_session_id()
            sessions[mac] = sid
            conn:publish(t_obs_event('session_start'), {
                value     = timestamp,
                namespace = { 'wifi', 'clients', uid, 'sessions', sid, 'session_start' },
            })
        else
            local sid = sessions[mac]
            if sid then
                conn:publish(t_obs_event('session_end'), {
                    value     = timestamp,
                    namespace = { 'wifi', 'clients', uid, 'sessions', sid, 'session_end' },
                })
                sessions[mac] = nil
            end
        end
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
            on_radio_state(msg)
        elseif which == 'event' then
            on_radio_event(msg)
        end
    end
end

------------------------------------------------------------------------
-- Global num_sta aggregator fiber
------------------------------------------------------------------------

---Subscribes to all radio client_event emissions and maintains a single
---wifi/num_sta count across all radios.
---@param conn Connection
---@param parent_scope Scope
local function run_global_num_sta(conn, parent_scope)
    local global_sta       = 0
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
            conn:retain(t_obs_metric('num_sta'), { value = global_sta, namespace = { 'wifi', 'num_sta' } })
        end
    end
end

------------------------------------------------------------------------
-- Service context helpers
------------------------------------------------------------------------

local function get_radio_cfg(ctx, radio_id)
    if not is_table(ctx.data) or not is_table(ctx.data.radios) then return nil end
    for _, r in ipairs(ctx.data.radios) do
        if r.name == radio_id then return r end
    end
    return nil
end

local function configure_radio(ctx, id)
    local radio_cfg = get_radio_cfg(ctx, id)
    if not radio_cfg then
        ctx.svc:obs_log('debug', { what = 'no_config_for_radio', radio = id })
        return
    end
    local cap   = cap_sdk.new_cap_ref(ctx.conn, 'radio', id)
    local ssids = is_table(ctx.data.ssids) and ctx.data.ssids or {}
    apply_radio_config(cap, radio_cfg, ssids, ctx.fs_configs_cap,
        is_table(ctx.data) and ctx.data.band_steering or nil, ctx.svc)
end

local function radio_fiber_body(ctx, id)
    configure_radio(ctx, id)
    radio_stats_loop(ctx.conn, id, get_radio_cfg(ctx, id), ctx.svc)
end

local function spawn_radio_scope(ctx, id)
    if ctx.radio_scopes[id] then
        ctx.radio_scopes[id]:cancel('reconfigure')
        ctx.radio_scopes[id] = nil
    end
    local scope, serr = ctx.parent_scope:child()
    if not scope then
        ctx.svc:obs_log('error', { what = 'radio_scope_failed', radio = id, err = serr })
        return
    end
    ctx.radio_scopes[id] = scope
    scope:spawn(function() radio_fiber_body(ctx, id) end)
end

local function remove_radio(ctx, id)
    if ctx.radio_scopes[id] then
        ctx.radio_scopes[id]:cancel('radio removed')
        ctx.radio_scopes[id] = nil
    end
end

local function apply_band_config(ctx)
    if ctx.band_cap and is_table(ctx.data) and is_table(ctx.data.band_steering) then
        apply_band_steering(ctx.band_cap, ctx.data.band_steering, ctx.svc)
    end
end

local function reapply_all_radios(ctx)
    for id in pairs(ctx.radio_scopes) do
        spawn_radio_scope(ctx, id)
    end
end

------------------------------------------------------------------------
-- Main service loop: message handlers
------------------------------------------------------------------------

local function on_cfg(ctx, msg)
    local payload = msg.payload
    if not is_table(payload) then
        ctx.svc:obs_log('warn', { what = 'invalid_config_payload' })
        return
    end
    local rev  = payload.rev
    local data = payload.data
    if type(rev) == 'number' and rev <= ctx.last_rev then
        ctx.svc:obs_log('debug', { what = 'stale_config', rev = rev, last_rev = ctx.last_rev })
    elseif not is_table(data) then
        ctx.svc:obs_log('warn', { what = 'config_data_not_table' })
    else
        ctx.last_rev = rev or ctx.last_rev
        ctx.data     = data
        ctx.svc:obs_event('config_applied', { rev = rev })
        reapply_all_radios(ctx)
        apply_band_config(ctx)
    end
end

local function on_radio_cap(ctx, msg)
    local id    = msg.topic and msg.topic[3]
    local state = msg.payload
    if state == 'added' then
        ctx.svc:obs_log('info', { what = 'radio_cap_added', radio = id })
        spawn_radio_scope(ctx, id)
    elseif state == 'removed' then
        ctx.svc:obs_log('info', { what = 'radio_cap_removed', radio = id })
        remove_radio(ctx, id)
    end
end

local function on_band_cap(ctx, msg)
    local state = msg.payload
    if state == 'added' then
        ctx.svc:obs_log('info', { what = 'band_cap_added' })
        ctx.band_cap = cap_sdk.new_cap_ref(ctx.conn, 'band', '1')
        apply_band_config(ctx)
    elseif state == 'removed' then
        ctx.svc:obs_log('info', { what = 'band_cap_removed' })
        ctx.band_cap = nil
    end
end

local function on_fs_cap(ctx, msg)
    local state = msg.payload
    if state == 'added' then
        ctx.svc:obs_log('info', { what = 'fs_configs_cap_added' })
        ctx.fs_configs_cap = cap_sdk.new_cap_ref(ctx.conn, 'fs', 'configs')
        reapply_all_radios(ctx)
    elseif state == 'removed' then
        ctx.svc:obs_log('info', { what = 'fs_configs_cap_removed' })
        ctx.fs_configs_cap = nil
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

    local ctx                = {
        conn           = conn,
        svc            = svc,
        parent_scope   = parent_scope,
        data           = nil, -- data field of last valid config
        last_rev       = -1,
        fs_configs_cap = nil, -- configs filesystem cap reference
        band_cap       = nil, -- band capability reference
        radio_scopes   = {},  -- radio_id → child scope
    }

    -- Subscribe to config topic
    local cfg_sub            = conn:subscribe({ 'cfg', 'wifi' })

    -- Subscribe to cap state notifications (radio, band, fs/configs)
    local radio_cap_listener = cap_sdk.new_cap_listener(conn, 'radio', '+')
    local band_cap_listener  = cap_sdk.new_cap_listener(conn, 'band', '1')
    local fs_cap_listener    = cap_sdk.new_cap_listener(conn, 'fs', 'configs')

    svc:status('running')
    svc:obs_log('info', 'service running')

    parent_scope:spawn(function() run_global_num_sta(conn, parent_scope) end)

    while true do
        local which, msg = perform(fibers.named_choice({
            cfg    = cfg_sub:recv_op(),
            radio  = radio_cap_listener.sub:recv_op(),
            band   = band_cap_listener.sub:recv_op(),
            fs     = fs_cap_listener.sub:recv_op(),
            cancel = parent_scope:cancel_op(),
        }))

        if which == 'cancel' then break end

        if not msg then
            svc:obs_log('debug', { what = 'subscription_closed', source = which })
        elseif which == 'cfg' then
            on_cfg(ctx, msg)
        elseif which == 'radio' then
            on_radio_cap(ctx, msg)
        elseif which == 'band' then
            on_band_cap(ctx, msg)
        elseif which == 'fs' then
            on_fs_cap(ctx, msg)
        end
    end

    -- Cleanup all radio scopes on exit
    for id, scope in pairs(ctx.radio_scopes) do
        scope:cancel('service stopping')
        ctx.radio_scopes[id] = nil
    end

    cfg_sub:unsubscribe()
    radio_cap_listener:close()
    band_cap_listener:close()
    fs_cap_listener:close()
end

return WifiService
