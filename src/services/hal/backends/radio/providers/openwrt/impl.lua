---OpenWrt radio backend implementation.
---All UCI writes use the shared uci singleton (reactor). Reads use get_value.
---Subprocess management (iw event, iw dev info, iw survey) is handled here.

local uci    = require "services.hal.backends.common.uci"
local fibers = require "fibers"
local exec   = require "fibers.io.exec"
local file   = require "fibers.io.file"

local SYSFS_STATS = {
    'rx_bytes', 'tx_bytes',
    'rx_packets', 'tx_packets',
    'rx_dropped', 'tx_dropped',
    'rx_errors', 'tx_errors',
}

---Read a single value from /sys/class/net/<iface>/statistics/<stat>
---@param iface string
---@param stat string
---@return number|nil
---@return string|nil err
local function read_sysfs_stat(iface, stat)
    local path = '/sys/class/net/' .. iface .. '/statistics/' .. stat
    local f, ferr = file.open(path, 'r')
    if not f then return nil, tostring(ferr) end
    local content, rerr = f:read_all()
    f:close()
    if not content then return nil, tostring(rerr) end
    local num = tonumber((content or ''):match('(%d+)'))
    if num == nil then return nil, stat .. ' invalid number' end
    return num, nil
end

---Parse `iw dev <iface> info` output into {txpower, channel, freq, width}
local function parse_iw_dev_info(raw)
    if not raw or raw == '' then return nil end
    local result = {}
    for line in raw:gmatch('[^\r\n]+') do
        local txpower = line:match('%s*txpower%s+([%d.]+)%s+dBm')
        if txpower then result.txpower = tonumber(txpower) end

        local chan, freq, width = line:match(
            '%s*channel%s+(%d+)%s+%(([%d]+)%s*MHz%),%s*width:%s*(%d+)%s*MHz'
        )
        if chan then
            result.channel = tonumber(chan)
            result.freq    = tonumber(freq)
            result.width   = tonumber(width)
        end
    end
    return result
end

---Parse `iw <iface> survey dump` for in-use noise value
local function parse_survey_noise(raw)
    if not raw or raw == '' then return nil end
    local in_use = false
    for line in raw:gmatch('[^\r\n]+') do
        if not in_use then
            if line:find('%[in use%]') then in_use = true end
        else
            local val = line:match('noise:%s*(%-?%d+%.?%d*)')
            if val then return tonumber(val) end
        end
    end
    return nil
end

---Parse `iw dev <iface> station get <mac>` output into {signal, tx_bytes, rx_bytes}
local function parse_station_info(raw)
    if not raw or raw == '' then return nil end
    local result = {}
    for line in raw:gmatch('[^\r\n]+') do
        local sig = line:match('%s*signal:%s*(%-?%d+)%s*dBm')
        if sig then result.signal = tonumber(sig) end

        local tx = line:match('%s*tx%s+bytes:%s+(%d+)')
        if tx then result.tx_bytes = tonumber(tx) end

        local rx = line:match('%s*rx%s+bytes:%s+(%d+)')
        if rx then result.rx_bytes = tonumber(rx) end
    end
    return result
end

------------------------------------------------------------------------
-- Backend functions
------------------------------------------------------------------------

---Get radio metadata from UCI wireless config.
---@param name string   UCI wifi-device section name (e.g. "radio0")
---@return table|nil  { path, type }
---@return string     err  "" on success
local function get_meta(name)
    local path = uci.get_value('wireless', name, 'path')
    local rtype = uci.get_value('wireless', name, 'type')
    if not path then
        return nil, "could not read wireless." .. name .. ".path from UCI"
    end
    return { path = path, type = rtype or '' }, ""
end

---Apply the staged radio config table to UCI and reload wireless.
---Uses the shared UCI reactor for debounced writes.
---@param staged table  Full staged config as accumulated by the driver
local function apply(staged)
    uci.ensure_started()
    local session = uci.new_session()
    local name = staged.name

    -- Delete any existing wifi-iface sections that belong to this radio but
    -- are not in the staged interfaces set, so stale sections don't linger.
    local staged_iface_names = {}
    for _, iface in ipairs(staged.interfaces or {}) do
        staged_iface_names[iface.name] = true
    end
    for _, sec in ipairs(uci.get_sections('wireless', 'wifi-iface')) do
        if uci.get_value('wireless', sec, 'device') == name
                and not staged_iface_names[sec] then
            session:delete('wireless', sec)
        end
    end

    -- Radio section (wifi-device) — ensure it exists before setting options
    session:set('wireless', name, 'wifi-device')
    if staged.path and staged.path ~= '' then
        session:set('wireless', name, 'path', staged.path)
    end
    if staged.type and staged.type ~= '' then
        session:set('wireless', name, 'type', staged.type)
    end
    if staged.band then
        session:set('wireless', name, 'band', staged.band)
    end
    if staged.channel ~= nil then
        session:set('wireless', name, 'channel', staged.channel)
    end
    if staged.htmode then
        session:set('wireless', name, 'htmode', staged.htmode)
    end
    if staged.channels then
        session:set('wireless', name, 'channels', table.concat(staged.channels, ' '))
    end
    if staged.txpower ~= nil then
        session:set('wireless', name, 'txpower', staged.txpower)
    end
    if staged.country then
        session:set('wireless', name, 'country', staged.country)
    end
    if staged.disabled ~= nil then
        session:set('wireless', name, 'disabled', staged.disabled)
    end

    -- Delete removed interfaces
    for _, iface_name in ipairs(staged.deleted_interfaces or {}) do
        session:delete('wireless', iface_name)
    end

    -- Write interface sections (wifi-iface)
    for _, iface in ipairs(staged.interfaces or {}) do
        -- Ensure the named section exists with the correct type before setting options
        session:set('wireless', iface.name, 'wifi-iface')
        session:set('wireless', iface.name, 'ifname',  iface.name)
        session:set('wireless', iface.name, 'device',  name)
        session:set('wireless', iface.name, 'mode',    iface.mode or 'ap')
        session:set('wireless', iface.name, 'ssid',    iface.ssid)
        session:set('wireless', iface.name, 'encryption', iface.encryption)
        session:set('wireless', iface.name, 'key',     iface.password or '')
        session:set('wireless', iface.name, 'network', iface.network)
        if iface.enable_steering then
            session:set('wireless', iface.name, 'bss_transition',    '1')
            session:set('wireless', iface.name, 'ieee80211k',        '1')
            session:set('wireless', iface.name, 'rrm_neighbor_report', '1')
            session:set('wireless', iface.name, 'rrm_beacon_report', '1')
        else
            session:set('wireless', iface.name, 'bss_transition',    '0')
            session:set('wireless', iface.name, 'ieee80211k',        '0')
            session:set('wireless', iface.name, 'rrm_neighbor_report', '0')
            session:set('wireless', iface.name, 'rrm_beacon_report', '0')
        end
    end

    local ok, err = session:commit('wireless', { { 'wifi', 'reload' } })
    if not ok then
        error('apply commit failed: ' .. tostring(err))
    end
end

---Delete all UCI config owned by this radio and reload wireless.
---Removes all wifi-iface sections whose device == name, then
---deletes the configurable options from the wifi-device section.
---@param name string  UCI radio section name
local function clear(name)
    uci.ensure_started()
    local session = uci.new_session()

    -- Delete all wifi-iface sections that belong to this radio
    for _, sec in ipairs(uci.get_sections('wireless', 'wifi-iface')) do
        if uci.get_value('wireless', sec, 'device') == name then
            session:delete('wireless', sec)
        end
    end

    -- Delete the configurable options on the wifi-device section
    -- (leave 'path' and 'type' intact since they are hardware facts)
    local OPT_KEYS = { 'band', 'channel', 'channels', 'htmode', 'txpower',
                       'country', 'disabled' }
    for _, opt in ipairs(OPT_KEYS) do
        if uci.get_value('wireless', name, opt) ~= nil then
            session:delete('wireless', name, opt)
        end
    end

    local ok, err = session:commit('wireless', { { 'wifi', 'reload' } })
    if not ok then
        error('clear failed: ' .. tostring(err))
    end
end

---Start monitoring client connect/disconnect events for the given interfaces.
---Calls cb(event) for each event where event = { mac, connected, interface }.
---Runs until the calling fiber's scope is cancelled.
---@param interfaces_set table  Live set of interface names to monitor (name → true)
---@param cb function            Called with each event table
local function watch_events(interfaces_set, cb)
    -- `iw event` reports events across all interfaces on stdout
    local proc = exec.command{ 'iw', 'event', stdout = 'pipe' }
    local stdout, serr = proc:stdout_stream()
    if serr then return end

    fibers.current_scope():finally(function()
        proc:kill()
    end)

    while true do
        local line, lerr = stdout:read_line()
        if lerr or not line then break end

        -- Parse: "wlan0: AP-STA-CONNECTED aa:bb:cc:dd:ee:ff"
        --   or   "wlan0: AP-STA-DISCONNECTED aa:bb:cc:dd:ee:ff"
        local iface2, mac2 = line:match('^(%S-):%s+AP%-STA%-CONNECTED%s+([%x:]+)$')
        local iface3, mac3 = line:match('^(%S-):%s+AP%-STA%-DISCONNECTED%s+([%x:]+)$')

        local match_iface, is_connected, match_mac
        if iface2 and mac2 then
            match_iface, is_connected, match_mac = iface2, true, mac2
        elseif iface3 and mac3 then
            match_iface, is_connected, match_mac = iface3, false, mac3
        end

        -- Only forward events for interfaces currently in the live set
        if match_iface and match_mac and interfaces_set[match_iface] then
            cb({ mac = match_mac, connected = is_connected, interface = match_iface })
        end
    end
end

---Get interface info: txpower, channel, freq, width.
---@param iface string
---@return table|nil  { txpower, channel, freq, width }
---@return string     err
local function get_iface_info(iface)
    local proc = exec.command{ 'iw', 'dev', iface, 'info', stdout = 'pipe' }
    local out, status, _, _, err = fibers.perform(proc:output_op())
    if status ~= 'exited' or err then return nil, tostring(err or 'iw dev info failed') end
    local result = parse_iw_dev_info(out)
    if not result then return nil, "could not parse iw dev info output" end
    return result, ""
end

---Get noise floor for an interface via survey dump.
---@param iface string
---@return number|nil  noise value
---@return string      err
local function get_iface_survey(iface)
    local proc = exec.command{ 'iw', iface, 'survey', 'dump', stdout = 'pipe' }
    local out, status, _, _, err = fibers.perform(proc:output_op())
    if status ~= 'exited' or err then return nil, tostring(err or 'iw survey failed') end
    local noise = parse_survey_noise(out)
    if noise == nil then return nil, "noise value not found" end
    return noise, ""
end

---Get per-client stats: signal, tx_bytes, rx_bytes.
---@param iface string
---@param mac string
---@return table|nil  { signal, tx_bytes, rx_bytes }
---@return string     err
local function get_station_info(iface, mac)
    local proc = exec.command{ 'iw', 'dev', iface, 'station', 'get', mac, stdout = 'pipe' }
    local out, status, _, _, err = fibers.perform(proc:output_op())
    if status ~= 'exited' or err then return nil, tostring(err or 'iw station get failed') end
    local result = parse_station_info(out)
    if not result then return nil, "could not parse station info" end
    return result, ""
end

return {
    get_meta        = get_meta,
    clear           = clear,
    apply           = apply,
    watch_events    = watch_events,
    get_iface_info  = get_iface_info,
    get_iface_survey = get_iface_survey,
    get_station_info = get_station_info,
    -- Re-export sysfs stat reader for use by the driver
    read_sysfs_stat = read_sysfs_stat,
    SYSFS_STATS     = SYSFS_STATS,
}
