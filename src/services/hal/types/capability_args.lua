local new = {}

---@class ModemGetOpts
---@field field string
---@field timescale? number
local ModemGetOpts = {}
ModemGetOpts.__index = ModemGetOpts

---Create a new ModemGetOpts.
---@param field string
---@param timescale? number
---@return ModemGetOpts?
---@return string error
function new.ModemGetOpts(field, timescale)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end

    if timescale ~= nil and (type(timescale) ~= 'number' or timescale < 0) then
        return nil, "invalid timescale"
    end

    return setmetatable({
        field = field,
        timescale = timescale,
    }, ModemGetOpts), ""
end

---@class ModemConnectOpts
---@field connection_string string
local ModemConnectOpts = {}
ModemConnectOpts.__index = ModemConnectOpts

---Create a new ModemConnectOpts.
---@param connection_string string
---@return ModemConnectOpts?
---@return string error
function new.ModemConnectOpts(connection_string)
    if type(connection_string) ~= 'string' or connection_string == '' then
        return nil, "invalid connection string"
    end
    return setmetatable({
        connection_string = connection_string,
    }, ModemConnectOpts), ""
end

---@class ModemSignalUpdateOpts
---@field frequency number
local ModemSignalUpdateOpts = {}
ModemSignalUpdateOpts.__index = ModemSignalUpdateOpts

---Create a new ModemSignalUpdateOpts.
---@param frequency number
---@return ModemSignalUpdateOpts?
---@return string error
function new.ModemSignalUpdateOpts(frequency)
    if type(frequency) ~= 'number' or frequency <= 0 then
        return nil, "invalid frequency"
    end
    return setmetatable({
        frequency = frequency,
    }, ModemSignalUpdateOpts), ""
end

---@class FilesystemReadOpts
---@field filename string
local FilesystemReadOpts = {}
FilesystemReadOpts.__index = FilesystemReadOpts

--- Validate that a filename contains no path separators or .. segments
---@param filename string
---@return boolean valid
---@return string? error
local function validate_filename(filename)
    if type(filename) ~= 'string' or filename == '' then
        return false, "filename must be a non-empty string"
    end

    if filename:find('/') or filename:find('\\') then
        return false, "filename cannot contain path separators"
    end

    if filename == '..' or filename:find('^%.%.') or filename:find('%.%.') then
        return false, "filename cannot contain .. segments"
    end

    return true, nil
end

---Create a new FilesystemReadOpts
---@param filename string
---@return FilesystemReadOpts?
---@return string error
function new.FilesystemReadOpts(filename)
    local valid, err = validate_filename(filename)
    if not valid then
        return nil, err
    end
    return setmetatable({
        filename = filename,
    }, FilesystemReadOpts), ""
end

---@class FilesystemWriteOpts
---@field filename string
---@field data string
local FilesystemWriteOpts = {}
FilesystemWriteOpts.__index = FilesystemWriteOpts

---Create a new FilesystemWriteOpts
---@param filename string
---@param data string
---@return FilesystemWriteOpts?
---@return string error
function new.FilesystemWriteOpts(filename, data)
    local valid, err = validate_filename(filename)
    if not valid then
        return nil, err
    end
    if type(data) ~= 'string' then
        return nil, "invalid data"
    end
    return setmetatable({
        filename = filename,
        data = data,
    }, FilesystemWriteOpts), ""
end

---@class UARTOpenOpts
---@field read boolean
---@field write boolean
local UARTOpenOpts = {}
UARTOpenOpts.__index = UARTOpenOpts

---Create a new UARTOpenOpts.
---At least one of read or write must be true.
---@param read boolean
---@param write boolean
---@return UARTOpenOpts?
---@return string error
function new.UARTOpenOpts(read, write)
    if type(read) ~= 'boolean' or type(write) ~= 'boolean' then
        return nil, "read and write must be booleans"
    end
    if not read and not write then
        return nil, "at least one of read or write must be true"
    end
    return setmetatable({
        read  = read,
        write = write,
    }, UARTOpenOpts), ""
end

---@class UARTWriteOpts
---@field data string
local UARTWriteOpts = {}
UARTWriteOpts.__index = UARTWriteOpts

---Create a new UARTWriteOpts.
---@param data string
---@return UARTWriteOpts?
---@return string error
function new.UARTWriteOpts(data)
    if type(data) ~= 'string' or data == '' then
        return nil, "data must be a non-empty string"
    end
    return setmetatable({
        data = data,
    }, UARTWriteOpts), ""
end

---@class MemoryGetOpts
---@field field string
---@field max_age number
local MemoryGetOpts = {}
MemoryGetOpts.__index = MemoryGetOpts

---Create a new MemoryGetOpts.
---@param field string
---@param max_age number
---@return MemoryGetOpts?
---@return string error
function new.MemoryGetOpts(field, max_age)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end
    if type(max_age) ~= 'number' or max_age < 0 then
        return nil, "invalid max_age"
    end
    return setmetatable({ field = field, max_age = max_age }, MemoryGetOpts), ""
end

---@class CpuGetOpts
---@field field string
---@field max_age number
local CpuGetOpts = {}
CpuGetOpts.__index = CpuGetOpts

---Create a new CpuGetOpts.
---@param field string
---@param max_age number
---@return CpuGetOpts?
---@return string error
function new.CpuGetOpts(field, max_age)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end
    if type(max_age) ~= 'number' or max_age < 0 then
        return nil, "invalid max_age"
    end
    return setmetatable({ field = field, max_age = max_age }, CpuGetOpts), ""
end

---@class ThermalGetOpts
---@field max_age number
local ThermalGetOpts = {}
ThermalGetOpts.__index = ThermalGetOpts

---Create a new ThermalGetOpts.
---@param max_age number
---@return ThermalGetOpts?
---@return string error
function new.ThermalGetOpts(max_age)
    if type(max_age) ~= 'number' or max_age < 0 then
        return nil, "invalid max_age"
    end
    return setmetatable({ max_age = max_age }, ThermalGetOpts), ""
end

---@class PlatformGetOpts
---@field field string
---@field max_age number
local PlatformGetOpts = {}
PlatformGetOpts.__index = PlatformGetOpts

---Create a new PlatformGetOpts.
---@param field string
---@param max_age number
---@return PlatformGetOpts?
---@return string error
function new.PlatformGetOpts(field, max_age)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end
    if type(max_age) ~= 'number' or max_age < 0 then
        return nil, "invalid max_age"
    end
    return setmetatable({ field = field, max_age = max_age }, PlatformGetOpts), ""
end

---@class PowerActionOpts
---@field delay? number
local PowerActionOpts = {}
PowerActionOpts.__index = PowerActionOpts

---Create a new PowerActionOpts.
---@param delay? number
---@return PowerActionOpts?
---@return string error
function new.PowerActionOpts(delay)
    if delay ~= nil and (type(delay) ~= 'number' or delay < 0) then
        return nil, "invalid delay"
    end
    return setmetatable({ delay = delay }, PowerActionOpts), ""
end

------------------------------------------------------------------------
-- Radio capability arg types
------------------------------------------------------------------------

local RADIO_VALID_BANDS = { '2g', '5g' }
local RADIO_VALID_HTMODES = {
    'HE20', 'HE40+', 'HE40-', 'HE80', 'HE160',
    'HT20', 'HT40+', 'HT40-',
    'VHT20', 'VHT40+', 'VHT40-', 'VHT80', 'VHT160',
}
local RADIO_VALID_ENCRYPTIONS = {
    'none', 'wep', 'psk', 'psk2', 'psk-mixed',
    'sae', 'sae-mixed', 'owe', 'wpa', 'wpa2', 'wpa3',
}
local RADIO_VALID_IFACE_MODES = { 'ap', 'sta', 'adhoc', 'mesh', 'monitor' }

local function is_in(value, list)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

---@alias RadioBand '2g'|'5g'
---@alias RadioHtmode 'HE20'|'HE40+'|'HE40-'|'HE80'|'HE160'|'HT20'|'HT40+'|'HT40-'|'VHT20'|'VHT40+'|'VHT40-'|'VHT80'|'VHT160'
---@alias RadioEncryption 'none'|'wep'|'psk'|'psk2'|'psk-mixed'|'sae'|'sae-mixed'|'owe'|'wpa'|'wpa2'|'wpa3'
---@alias RadioIfaceMode 'ap'|'sta'|'adhoc'|'mesh'|'monitor'

---@class RadioSetChannelsOpts
---@field band RadioBand
---@field channel number|string        -- channel number, string, or "auto"
---@field htmode RadioHtmode
---@field channels? (number|string)[]  -- required when channel == "auto"
local RadioSetChannelsOpts = {}
RadioSetChannelsOpts.__index = RadioSetChannelsOpts

---@param band RadioBand
---@param channel number|string
---@param htmode RadioHtmode
---@param channels? (number|string)[]
---@return RadioSetChannelsOpts?
---@return string error
function new.RadioSetChannelsOpts(band, channel, htmode, channels)
    if not is_in(band, RADIO_VALID_BANDS) then
        return nil, 'band must be one of: ' .. table.concat(RADIO_VALID_BANDS, ', ')
    end
    if not is_in(htmode, RADIO_VALID_HTMODES) then
        return nil, 'htmode must be one of: ' .. table.concat(RADIO_VALID_HTMODES, ', ')
    end
    if channel == 'auto' then
        if type(channels) ~= 'table' or #channels == 0 then
            return nil, 'channels must be a non-empty list when channel is "auto"'
        end
    elseif type(channel) ~= 'number' and type(channel) ~= 'string' then
        return nil, 'channel must be a number, string, or "auto"'
    end
    return setmetatable({
        band = band, channel = channel, htmode = htmode, channels = channels,
    }, RadioSetChannelsOpts), ""
end

---@class RadioSetTxpowerOpts
---@field txpower number|string
local RadioSetTxpowerOpts = {}
RadioSetTxpowerOpts.__index = RadioSetTxpowerOpts

---@param txpower number|string
---@return RadioSetTxpowerOpts?
---@return string error
function new.RadioSetTxpowerOpts(txpower)
    if type(txpower) ~= 'number' and type(txpower) ~= 'string' then
        return nil, 'txpower must be a number or string'
    end
    return setmetatable({ txpower = txpower }, RadioSetTxpowerOpts), ""
end

---@class RadioSetCountryOpts
---@field country string  -- 2-letter ISO code, normalised to uppercase
local RadioSetCountryOpts = {}
RadioSetCountryOpts.__index = RadioSetCountryOpts

---@param country string  ISO-3166-1 alpha-2 code
---@return RadioSetCountryOpts?
---@return string error
function new.RadioSetCountryOpts(country)
    if type(country) ~= 'string' or #country ~= 2 then
        return nil, 'country must be a 2-character string'
    end
    return setmetatable({ country = country:upper() }, RadioSetCountryOpts), ""
end

---@class RadioSetEnabledOpts
---@field enabled boolean
local RadioSetEnabledOpts = {}
RadioSetEnabledOpts.__index = RadioSetEnabledOpts

---@param enabled boolean
---@return RadioSetEnabledOpts?
---@return string error
function new.RadioSetEnabledOpts(enabled)
    if type(enabled) ~= 'boolean' then
        return nil, 'enabled must be a boolean'
    end
    return setmetatable({ enabled = enabled }, RadioSetEnabledOpts), ""
end

---@class RadioAddInterfaceOpts
---@field ssid string
---@field encryption RadioEncryption
---@field password string
---@field network string
---@field mode RadioIfaceMode
---@field enable_steering boolean
local RadioAddInterfaceOpts = {}
RadioAddInterfaceOpts.__index = RadioAddInterfaceOpts

---@param ssid string
---@param encryption RadioEncryption
---@param password string
---@param network string
---@param mode RadioIfaceMode
---@param enable_steering boolean
---@return RadioAddInterfaceOpts?
---@return string error
function new.RadioAddInterfaceOpts(ssid, encryption, password, network, mode, enable_steering)
    if type(ssid) ~= 'string' or ssid == '' then
        return nil, 'ssid must be a non-empty string'
    end
    if not is_in(encryption, RADIO_VALID_ENCRYPTIONS) then
        return nil, 'encryption must be one of: ' .. table.concat(RADIO_VALID_ENCRYPTIONS, ', ')
    end
    if type(password) ~= 'string' then
        return nil, 'password must be a string'
    end
    if type(network) ~= 'string' or network == '' then
        return nil, 'network must be a non-empty string'
    end
    if not is_in(mode, RADIO_VALID_IFACE_MODES) then
        return nil, 'mode must be one of: ' .. table.concat(RADIO_VALID_IFACE_MODES, ', ')
    end
    if type(enable_steering) ~= 'boolean' then
        return nil, 'enable_steering must be a boolean'
    end
    return setmetatable({
        ssid = ssid, encryption = encryption, password = password,
        network = network, mode = mode, enable_steering = enable_steering,
    }, RadioAddInterfaceOpts), ""
end

---@class RadioDeleteInterfaceOpts
---@field interface string
local RadioDeleteInterfaceOpts = {}
RadioDeleteInterfaceOpts.__index = RadioDeleteInterfaceOpts

---@param interface string
---@return RadioDeleteInterfaceOpts?
---@return string error
function new.RadioDeleteInterfaceOpts(interface)
    if type(interface) ~= 'string' or interface == '' then
        return nil, 'interface must be a non-empty string'
    end
    return setmetatable({ interface = interface }, RadioDeleteInterfaceOpts), ""
end

---@class RadioSetReportPeriodOpts
---@field period number  -- seconds, must be > 0
local RadioSetReportPeriodOpts = {}
RadioSetReportPeriodOpts.__index = RadioSetReportPeriodOpts

---@param period number  seconds, must be > 0
---@return RadioSetReportPeriodOpts?
---@return string error
function new.RadioSetReportPeriodOpts(period)
    if type(period) ~= 'number' or period <= 0 then
        return nil, 'period must be a positive number'
    end
    return setmetatable({ period = period }, RadioSetReportPeriodOpts), ""
end

---@class RadioCapabilityReply
---@field ok boolean
---@field reason? string  -- error message on failure; generated interface name on add_interface success

------------------------------------------------------------------------
-- Band capability arg types
------------------------------------------------------------------------

local BAND_VALID_KICK_MODES   = { 'none', 'compare', 'absolute', 'both' }
local BAND_VALID_RRM_MODES    = { 'PAT' }
local BAND_VALID_LEGACY_KEYS  = {
    'eval_probe_req', 'eval_assoc_req', 'eval_auth_req',
    'min_probe_count', 'deny_assoc_reason', 'deny_auth_reason',
}
local BAND_VALID_KICKING_OPTS = {
    'rssi_center', 'rssi_reward_threshold', 'rssi_reward',
    'rssi_penalty_threshold', 'rssi_penalty', 'rssi_weight',
    'channel_util_reward_threshold', 'channel_util_reward',
    'channel_util_penalty_threshold', 'channel_util_penalty',
}
local BAND_VALID_UPDATE_KEYS  = { 'client', 'chan_util', 'hostapd', 'beacon_reports', 'tcp_con' }
local BAND_VALID_CLEANUP_KEYS = { 'probe', 'client', 'ap' }
local BAND_VALID_NET_METHODS  = { 'broadcast', 'tcp+umdns', 'multicast', 'tcp' }
local BAND_VALID_NET_OPTS     = { 'ip', 'port', 'broadcast_port', 'enable_encryption' }
local BAND_VALID_BANDS        = { '2G', '5G' }
local BAND_VALID_SUPPORTS     = { 'ht', 'vht' }

---@alias BandId '2G'|'5G'
---@alias BandKickMode 'none'|'compare'|'absolute'|'both'
---@alias BandRrmMode 'PAT'
---@alias BandNetworkingMethod 'broadcast'|'tcp+umdns'|'multicast'|'tcp'
---@alias BandSupportType 'ht'|'vht'

---@class BandSetLogLevelOpts
---@field level number  -- non-negative integer
local BandSetLogLevelOpts = {}
BandSetLogLevelOpts.__index = BandSetLogLevelOpts

---@param level number  non-negative integer
---@return BandSetLogLevelOpts?
---@return string error
function new.BandSetLogLevelOpts(level)
    if type(level) ~= 'number' or level < 0 then
        return nil, 'level must be a non-negative number'
    end
    return setmetatable({ level = level }, BandSetLogLevelOpts), ""
end

---@class BandSetKickingOpts
---@field mode BandKickMode
---@field bandwidth_threshold number
---@field kicking_threshold number
---@field evals_before_kick number
local BandSetKickingOpts = {}
BandSetKickingOpts.__index = BandSetKickingOpts

---@param mode BandKickMode
---@param bandwidth_threshold number
---@param kicking_threshold number
---@param evals_before_kick number
---@return BandSetKickingOpts?
---@return string error
function new.BandSetKickingOpts(mode, bandwidth_threshold, kicking_threshold, evals_before_kick)
    if not is_in(mode, BAND_VALID_KICK_MODES) then
        return nil, 'mode must be one of: ' .. table.concat(BAND_VALID_KICK_MODES, ', ')
    end
    if type(bandwidth_threshold) ~= 'number' or bandwidth_threshold < 0 then
        return nil, 'bandwidth_threshold must be a non-negative number'
    end
    if type(kicking_threshold) ~= 'number' or kicking_threshold < 0 then
        return nil, 'kicking_threshold must be a non-negative number'
    end
    if type(evals_before_kick) ~= 'number' or evals_before_kick < 0 then
        return nil, 'evals_before_kick must be a non-negative integer'
    end
    return setmetatable({
        mode                = mode,
        bandwidth_threshold = bandwidth_threshold,
        kicking_threshold   = kicking_threshold,
        evals_before_kick   = evals_before_kick,
    }, BandSetKickingOpts), ""
end

---@class BandSetStationCountingOpts
---@field use_station_count boolean
---@field max_station_diff number
local BandSetStationCountingOpts = {}
BandSetStationCountingOpts.__index = BandSetStationCountingOpts

---@param use_station_count boolean
---@param max_station_diff number
---@return BandSetStationCountingOpts?
---@return string error
function new.BandSetStationCountingOpts(use_station_count, max_station_diff)
    if type(use_station_count) ~= 'boolean' then
        return nil, 'use_station_count must be a boolean'
    end
    if type(max_station_diff) ~= 'number' or max_station_diff < 0 then
        return nil, 'max_station_diff must be a non-negative integer'
    end
    return setmetatable({
        use_station_count = use_station_count,
        max_station_diff  = max_station_diff,
    }, BandSetStationCountingOpts), ""
end

---@class BandSetRrmModeOpts
---@field mode BandRrmMode
local BandSetRrmModeOpts = {}
BandSetRrmModeOpts.__index = BandSetRrmModeOpts

---@param mode BandRrmMode
---@return BandSetRrmModeOpts?
---@return string error
function new.BandSetRrmModeOpts(mode)
    if not is_in(mode, BAND_VALID_RRM_MODES) then
        return nil, 'mode must be one of: ' .. table.concat(BAND_VALID_RRM_MODES, ', ')
    end
    return setmetatable({ mode = mode }, BandSetRrmModeOpts), ""
end

---@class BandSetNeighbourReportsOpts
---@field dyn_report_num number
---@field disassoc_report_len number
local BandSetNeighbourReportsOpts = {}
BandSetNeighbourReportsOpts.__index = BandSetNeighbourReportsOpts

---@param dyn_report_num number
---@param disassoc_report_len number
---@return BandSetNeighbourReportsOpts?
---@return string error
function new.BandSetNeighbourReportsOpts(dyn_report_num, disassoc_report_len)
    local dyn = tonumber(dyn_report_num)
    local dis = tonumber(disassoc_report_len)
    if not dyn or dyn < 0 then
        return nil, 'dyn_report_num must be a non-negative integer'
    end
    if not dis or dis < 0 then
        return nil, 'disassoc_report_len must be a non-negative integer'
    end
    return setmetatable({
        dyn_report_num      = dyn,
        disassoc_report_len = dis,
    }, BandSetNeighbourReportsOpts), ""
end

---@class BandLegacyOpts
---@field eval_probe_req? boolean
---@field eval_assoc_req? boolean
---@field eval_auth_req? boolean
---@field min_probe_count? number
---@field deny_auth_reason? number
---@field deny_assoc_reason? number

---@class BandSetLegacyOptionsOpts
---@field opts BandLegacyOpts
local BandSetLegacyOptionsOpts = {}
BandSetLegacyOptionsOpts.__index = BandSetLegacyOptionsOpts

---@param opts BandLegacyOpts
---@return BandSetLegacyOptionsOpts?
---@return string error
function new.BandSetLegacyOptionsOpts(opts)
    if type(opts) ~= 'table' then
        return nil, 'opts must be a table'
    end
    for key in pairs(opts) do
        if not is_in(key, BAND_VALID_LEGACY_KEYS) then
            return nil, 'unknown legacy option key: ' .. tostring(key)
        end
    end
    return setmetatable({ opts = opts }, BandSetLegacyOptionsOpts), ""
end

---@class BandSetBandPriorityOpts
---@field band BandId
---@field priority number
local BandSetBandPriorityOpts = {}
BandSetBandPriorityOpts.__index = BandSetBandPriorityOpts

---@param band BandId
---@param priority number
---@return BandSetBandPriorityOpts?
---@return string error
function new.BandSetBandPriorityOpts(band, priority)
    local b = type(band) == 'string' and band:upper() or ''
    if not is_in(b, BAND_VALID_BANDS) then
        return nil, 'band must be "2G" or "5G"'
    end
    if type(priority) ~= 'number' or priority < 0 then
        return nil, 'priority must be a non-negative number'
    end
    return setmetatable({ band = b, priority = priority }, BandSetBandPriorityOpts), ""
end

---@class BandKickingOptions
---@field rssi_center? number
---@field rssi_reward_threshold? number
---@field rssi_reward? number
---@field rssi_penalty_threshold? number
---@field rssi_penalty? number
---@field rssi_weight? number
---@field channel_util_reward_threshold? number
---@field channel_util_reward? number
---@field channel_util_penalty_threshold? number
---@field channel_util_penalty? number

---@class BandSetBandKickingOpts
---@field band BandId
---@field options BandKickingOptions
local BandSetBandKickingOpts = {}
BandSetBandKickingOpts.__index = BandSetBandKickingOpts

---@param band BandId
---@param options BandKickingOptions
---@return BandSetBandKickingOpts?
---@return string error
function new.BandSetBandKickingOpts(band, options)
    local b = type(band) == 'string' and band:upper() or ''
    if not is_in(b, BAND_VALID_BANDS) then
        return nil, 'band must be "2G" or "5G"'
    end
    if type(options) ~= 'table' then
        return nil, 'options must be a table'
    end
    for key, value in pairs(options) do
        if not is_in(key, BAND_VALID_KICKING_OPTS) then
            return nil, 'unknown band kicking option: ' .. tostring(key)
        end
        if tonumber(value) == nil then
            return nil, 'value for ' .. key .. ' must be a number'
        end
    end
    return setmetatable({ band = b, options = options }, BandSetBandKickingOpts), ""
end

---@class BandSetSupportBonusOpts
---@field band BandId
---@field support BandSupportType
---@field reward number
local BandSetSupportBonusOpts = {}
BandSetSupportBonusOpts.__index = BandSetSupportBonusOpts

---@param band BandId
---@param support BandSupportType
---@param reward number
---@return BandSetSupportBonusOpts?
---@return string error
function new.BandSetSupportBonusOpts(band, support, reward)
    local b = type(band) == 'string' and band:upper() or ''
    if not is_in(b, BAND_VALID_BANDS) then
        return nil, 'band must be "2G" or "5G"'
    end
    if not is_in(support, BAND_VALID_SUPPORTS) then
        return nil, 'support must be "ht" or "vht"'
    end
    if type(reward) ~= 'number' then
        return nil, 'reward must be a number'
    end
    return setmetatable({ band = b, support = support, reward = reward }, BandSetSupportBonusOpts), ""
end

---@class BandUpdateFreqOptions
---@field client? number
---@field chan_util? number
---@field hostapd? number
---@field beacon_reports? number
---@field tcp_con? number

---@class BandSetUpdateFreqOpts
---@field updates BandUpdateFreqOptions
local BandSetUpdateFreqOpts = {}
BandSetUpdateFreqOpts.__index = BandSetUpdateFreqOpts

---@param updates BandUpdateFreqOptions
---@return BandSetUpdateFreqOpts?
---@return string error
function new.BandSetUpdateFreqOpts(updates)
    if type(updates) ~= 'table' then
        return nil, 'updates must be a table'
    end
    for key, value in pairs(updates) do
        if not is_in(key, BAND_VALID_UPDATE_KEYS) then
            return nil, 'unknown update key: ' .. tostring(key)
        end
        if type(value) ~= 'number' or value < 0 then
            return nil, 'value for ' .. key .. ' must be a non-negative number'
        end
    end
    return setmetatable({ updates = updates }, BandSetUpdateFreqOpts), ""
end

---@class BandSetClientInactiveKickoffOpts
---@field timeout number
local BandSetClientInactiveKickoffOpts = {}
BandSetClientInactiveKickoffOpts.__index = BandSetClientInactiveKickoffOpts

---@param timeout number  non-negative integer
---@return BandSetClientInactiveKickoffOpts?
---@return string error
function new.BandSetClientInactiveKickoffOpts(timeout)
    local t = tonumber(timeout)
    if not t or t < 0 then
        return nil, 'timeout must be a non-negative integer'
    end
    return setmetatable({ timeout = t }, BandSetClientInactiveKickoffOpts), ""
end

---@class BandCleanupTimeouts
---@field probe? number
---@field client? number
---@field ap? number

---@class BandSetCleanupOpts
---@field timeouts BandCleanupTimeouts
local BandSetCleanupOpts = {}
BandSetCleanupOpts.__index = BandSetCleanupOpts

---@param timeouts BandCleanupTimeouts
---@return BandSetCleanupOpts?
---@return string error
function new.BandSetCleanupOpts(timeouts)
    if type(timeouts) ~= 'table' then
        return nil, 'timeouts must be a table'
    end
    for key, value in pairs(timeouts) do
        if not is_in(key, BAND_VALID_CLEANUP_KEYS) then
            return nil, 'unknown cleanup key: ' .. tostring(key)
        end
        if type(value) ~= 'number' or value < 0 then
            return nil, 'value for cleanup.' .. key .. ' must be a non-negative number'
        end
    end
    return setmetatable({ timeouts = timeouts }, BandSetCleanupOpts), ""
end

---@class BandNetworkingOptions
---@field ip? string
---@field port? number
---@field broadcast_port? number
---@field enable_encryption? boolean

---@class BandSetNetworkingOpts
---@field method BandNetworkingMethod
---@field options BandNetworkingOptions
local BandSetNetworkingOpts = {}
BandSetNetworkingOpts.__index = BandSetNetworkingOpts

---@param method BandNetworkingMethod
---@param options BandNetworkingOptions
---@return BandSetNetworkingOpts?
---@return string error
function new.BandSetNetworkingOpts(method, options)
    if not is_in(method, BAND_VALID_NET_METHODS) then
        return nil, 'method must be one of: ' .. table.concat(BAND_VALID_NET_METHODS, ', ')
    end
    if type(options) ~= 'table' then
        return nil, 'options must be a table'
    end
    for key, value in pairs(options) do
        if not is_in(key, BAND_VALID_NET_OPTS) then
            return nil, 'unknown networking option: ' .. tostring(key)
        end
        if key == 'ip' and type(value) ~= 'string' then
            return nil, 'networking.ip must be a string'
        end
        if (key == 'port' or key == 'broadcast_port') and type(value) ~= 'number' then
            return nil, 'networking.' .. key .. ' must be a number'
        end
        if key == 'enable_encryption' and type(value) ~= 'boolean' then
            return nil, 'networking.enable_encryption must be a boolean'
        end
    end
    return setmetatable({ method = method, options = options }, BandSetNetworkingOpts), ""
end

---@class BandCapabilityReply
---@field ok boolean
---@field reason? string  -- error message on failure

return {
    ModemGetOpts = ModemGetOpts,
    ModemConnectOpts = ModemConnectOpts,
    FilesystemReadOpts = FilesystemReadOpts,
    FilesystemWriteOpts = FilesystemWriteOpts,
    UARTOpenOpts = UARTOpenOpts,
    UARTWriteOpts = UARTWriteOpts,
    MemoryGetOpts = MemoryGetOpts,
    CpuGetOpts = CpuGetOpts,
    ThermalGetOpts = ThermalGetOpts,
    PlatformGetOpts = PlatformGetOpts,
    PowerActionOpts = PowerActionOpts,
    RadioSetChannelsOpts = RadioSetChannelsOpts,
    RadioSetTxpowerOpts = RadioSetTxpowerOpts,
    RadioSetCountryOpts = RadioSetCountryOpts,
    RadioSetEnabledOpts = RadioSetEnabledOpts,
    RadioAddInterfaceOpts = RadioAddInterfaceOpts,
    RadioDeleteInterfaceOpts = RadioDeleteInterfaceOpts,
    RadioSetReportPeriodOpts = RadioSetReportPeriodOpts,
    BandSetLogLevelOpts = BandSetLogLevelOpts,
    BandSetKickingOpts = BandSetKickingOpts,
    BandSetStationCountingOpts = BandSetStationCountingOpts,
    BandSetRrmModeOpts = BandSetRrmModeOpts,
    BandSetNeighbourReportsOpts = BandSetNeighbourReportsOpts,
    BandSetLegacyOptionsOpts = BandSetLegacyOptionsOpts,
    BandSetBandPriorityOpts = BandSetBandPriorityOpts,
    BandSetBandKickingOpts = BandSetBandKickingOpts,
    BandSetSupportBonusOpts = BandSetSupportBonusOpts,
    BandSetUpdateFreqOpts = BandSetUpdateFreqOpts,
    BandSetClientInactiveKickoffOpts = BandSetClientInactiveKickoffOpts,
    BandSetCleanupOpts = BandSetCleanupOpts,
    BandSetNetworkingOpts = BandSetNetworkingOpts,
    new = new,
}
