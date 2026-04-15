---OpenWrt DAWN band steering backend implementation.
---Translates staged driver config to dawn UCI sections via the shared UCI reactor.

local uci = require "services.hal.backends.common.uci"

local BAND_SECTION = {
    ['2G'] = '802_11g',
    ['5G'] = '802_11a',
}

local KICK_MODE_ID = {
    none     = 0,
    compare  = 1,
    absolute = 2,
    both     = 3,
}

local NETWORKING_METHOD_ID = {
    broadcast   = 0,
    ['tcp+umdns'] = 2,
    multicast   = 2,
    tcp         = 3,
}

local BAND_KICKING_KEYS = {
    rssi_center                    = 'rssi_center',
    rssi_reward_threshold          = 'rssi_val',
    rssi_reward                    = 'rssi',
    rssi_penalty_threshold         = 'low_rssi_val',
    rssi_penalty                   = 'low_rssi',
    rssi_weight                    = 'rssi_weight',
    channel_util_reward_threshold  = 'chan_util_val',
    channel_util_reward            = 'chan_util',
    channel_util_penalty_threshold = 'max_chan_util_val',
    channel_util_penalty           = 'max_chan_util',
}

-- Fixed sections required in a clean DAWN config
local REQUIRED_SECTIONS = {
    { name = 'global',   type = 'metric'  },
    { name = '802_11g',  type = 'metric'  },
    { name = '802_11a',  type = 'metric'  },
    { name = 'gbltime',  type = 'times'   },
    { name = 'gblnet',   type = 'network' },
    { name = 'localcfg', type = 'local'   },
}

------------------------------------------------------------------------
-- Backend functions
------------------------------------------------------------------------

---Reset DAWN's UCI config to a clean base state.
---Deletes all non-hostapd sections, re-creates required sections with empty defaults.
---Uses a synchronous commit so callers get immediate success/failure.
---@return boolean ok
---@return string  err
local function clear()
    local session = uci.new_session()

    -- Delete each known managed section (if it exists)
    for _, sec in ipairs(REQUIRED_SECTIONS) do
        session:delete('dawn', sec.name)
    end

    -- Re-create required sections with their type
    for _, sec in ipairs(REQUIRED_SECTIONS) do
        session:add('dawn', sec.type)
        -- UCI anonymous sections need to be renamed; the router adds them
        -- sequentially, so we rely on the backend knowing the section names.
        -- Named sections in OpenWrt UCI are addressed by name directly.
    end

    local ok, err = session:commit_sync('dawn')
    if not ok then
        return false, "failed to clear DAWN config: " .. tostring(err)
    end

    -- Rename the anonymous sections back to their canonical names by
    -- doing explicit set operations on each section name.
    local rename_session = uci.new_session()
    for _, sec in ipairs(REQUIRED_SECTIONS) do
        rename_session:set('dawn', sec.name, sec.type)
    end
    local rok, rerr = rename_session:commit_sync('dawn')
    if not rok then
        return false, "failed to re-create DAWN sections: " .. tostring(rerr)
    end

    return true, ""
end

---Apply the staged band config table to DAWN UCI and restart the daemon.
---@param staged table  Band staged config as accumulated by the driver
local function apply(staged)
    uci.ensure_started()
    local session = uci.new_session()

    -- log_level
    if staged.log_level ~= nil then
        session:set('dawn', 'localcfg', 'log_level', staged.log_level)
    end

    -- kicking
    if staged.kicking then
        local k  = staged.kicking
        if k.mode ~= nil then
            session:set('dawn', 'global', 'kicking',
                tostring(KICK_MODE_ID[k.mode] or 0))
        end
        if k.bandwidth_threshold ~= nil then
            session:set('dawn', 'global', 'bandwidth_threshold', k.bandwidth_threshold)
        end
        if k.kicking_threshold ~= nil then
            session:set('dawn', 'global', 'kicking_threshold', k.kicking_threshold)
        end
        if k.evals_before_kick ~= nil then
            session:set('dawn', 'global', 'min_number_to_kick', k.evals_before_kick)
        end
    end

    -- station counting
    if staged.station_counting then
        local sc = staged.station_counting
        if sc.use_station_count ~= nil then
            session:set('dawn', 'global', 'use_station_count',
                sc.use_station_count and '1' or '0')
        end
        if sc.max_station_diff ~= nil then
            session:set('dawn', 'global', 'max_station_diff', sc.max_station_diff)
        end
    end

    -- rrm_mode
    if staged.rrm_mode ~= nil then
        session:set('dawn', 'global', 'rrm_mode', staged.rrm_mode)
    end

    -- neighbour reports
    if staged.neighbour_reports then
        local nr = staged.neighbour_reports
        if nr.dyn_report_num ~= nil then
            session:set('dawn', 'global', 'set_hostapd_nr', nr.dyn_report_num)
        end
        if nr.disassoc_report_len ~= nil then
            session:set('dawn', 'global', 'disassoc_nr_length', nr.disassoc_report_len)
        end
    end

    -- legacy options (flat key-value under global)
    if staged.legacy then
        for key, value in pairs(staged.legacy) do
            session:set('dawn', 'global', key, value)
        end
    end

    -- band priorities and kicking params
    for band_key, section_name in pairs(BAND_SECTION) do
        local bp = staged.band_priorities and staged.band_priorities[band_key]
        if bp then
            if bp.initial_score ~= nil then
                session:set('dawn', section_name, 'initial_score', bp.initial_score)
            end
        end

        local bk = staged.band_kicking and staged.band_kicking[band_key]
        if bk then
            for driver_key, uci_key in pairs(BAND_KICKING_KEYS) do
                if bk[driver_key] ~= nil then
                    session:set('dawn', section_name, uci_key, bk[driver_key])
                end
            end
        end

        local sb = staged.support_bonus and staged.support_bonus[band_key]
        if sb then
            for _, support in ipairs({'ht', 'vht'}) do
                if sb[support] ~= nil then
                    session:set('dawn', section_name, support .. '_support', sb[support])
                end
            end
        end
    end

    -- update frequencies
    if staged.update_freq then
        for key, freq in pairs(staged.update_freq) do
            session:set('dawn', 'gbltime', 'update_' .. key, freq)
        end
    end

    -- client inactive kickoff (con_timeout)
    if staged.con_timeout ~= nil then
        session:set('dawn', 'gbltime', 'con_timeout', staged.con_timeout)
    end

    -- cleanup timeouts
    if staged.cleanup then
        for key, timeout in pairs(staged.cleanup) do
            session:set('dawn', 'gbltime', 'remove_' .. key, timeout)
        end
    end

    -- networking
    if staged.networking then
        local net = staged.networking
        if net.method ~= nil then
            local method_id = NETWORKING_METHOD_ID[net.method]
            if method_id ~= nil then
                session:set('dawn', 'gblnet', 'method', tostring(method_id))
            end
        end
        if net.ip ~= nil then
            session:set('dawn', 'gblnet', 'tcp_ip', net.ip)
        end
        if net.port ~= nil then
            session:set('dawn', 'gblnet', 'tcp_port', net.port)
        end
        if net.broadcast_port ~= nil then
            session:set('dawn', 'gblnet', 'broadcast_port', net.broadcast_port)
        end
        if net.enable_encryption ~= nil then
            session:set('dawn', 'gblnet', 'use_symm_enc',
                net.enable_encryption and '1' or '0')
        end
    end

    session:commit('dawn', { { 'service', 'dawn', 'restart' } })
end

return {
    clear        = clear,
    apply        = apply,
}
