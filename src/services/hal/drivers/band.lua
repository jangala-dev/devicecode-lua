local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"
local provider  = require "services.hal.backends.band.provider"
local cap_args  = require "services.hal.types.capability_args"

local fibers  = require "fibers"
local channel = require "fibers.channel"

local CONTROL_Q_LEN = 16

local VALID_KICK_MODES = { 'none', 'compare', 'absolute', 'both' }
local VALID_RRM_MODES  = { 'PAT' }
local VALID_LEGACY_KEYS = {
    'eval_probe_req', 'eval_assoc_req', 'eval_auth_req',
    'min_probe_count', 'deny_assoc_reason', 'deny_auth_reason',
}
local VALID_BAND_KICKING_OPTS = {
    'rssi_center', 'rssi_reward_threshold', 'rssi_reward',
    'rssi_penalty_threshold', 'rssi_penalty', 'rssi_weight',
    'channel_util_reward_threshold', 'channel_util_reward',
    'channel_util_penalty_threshold', 'channel_util_penalty',
}
local VALID_UPDATE_KEYS = { 'client', 'chan_util', 'hostapd', 'beacon_reports', 'tcp_con' }
local VALID_CLEANUP_KEYS = { 'probe', 'client', 'ap' }
local VALID_NETWORKING_METHODS = { 'broadcast', 'tcp+umdns', 'multicast', 'tcp' }
local VALID_NETWORKING_OPTS = { 'ip', 'port', 'broadcast_port', 'enable_encryption' }
local VALID_BANDS    = { '2G', '5G' }
local VALID_SUPPORTS = { 'ht', 'vht' }

local function is_in(value, list)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

---@class BandDriver
---@field id string       Always '1'
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field staged table    In-memory staged band config
---@field initialised boolean
---@field caps_applied boolean
---@field log table
---@field backend table
local BandDriver = {}
BandDriver.__index = BandDriver

------------------------------------------------------------------------
-- RPC handler methods
------------------------------------------------------------------------

---@param opts BandSetLogLevelOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_log_level(opts)
    if getmetatable(opts) ~= cap_args.BandSetLogLevelOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetLogLevelOpts(opts.level)
        if not casted then return false, err end
        opts = casted
    end
    local level = opts.level
    if type(level) ~= 'number' or level < 0 then
        return false, 'level must be a non-negative number'
    end
    self.staged.log_level = level
    return true
end

---@param opts BandSetKickingOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_kicking(opts)
    if getmetatable(opts) ~= cap_args.BandSetKickingOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetKickingOpts(
            opts.mode, opts.bandwidth_threshold, opts.kicking_threshold, opts.evals_before_kick)
        if not casted then return false, err end
        opts = casted
    end
    if not is_in(opts.mode, VALID_KICK_MODES) then
        return false, 'mode must be one of: ' .. table.concat(VALID_KICK_MODES, ', ')
    end
    if type(opts.bandwidth_threshold) ~= 'number' or opts.bandwidth_threshold < 0 then
        return false, 'bandwidth_threshold must be a non-negative number'
    end
    if type(opts.kicking_threshold) ~= 'number' or opts.kicking_threshold < 0 then
        return false, 'kicking_threshold must be a non-negative number'
    end
    if type(opts.evals_before_kick) ~= 'number' or opts.evals_before_kick < 0 then
        return false, 'evals_before_kick must be a non-negative integer'
    end
    self.staged.kicking = {
        mode                = opts.mode,
        bandwidth_threshold = opts.bandwidth_threshold,
        kicking_threshold   = opts.kicking_threshold,
        evals_before_kick   = opts.evals_before_kick,
    }
    return true
end

---@param opts BandSetStationCountingOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_station_counting(opts)
    if getmetatable(opts) ~= cap_args.BandSetStationCountingOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetStationCountingOpts(opts.use_station_count, opts.max_station_diff)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.use_station_count) ~= 'boolean' then
        return false, 'use_station_count must be a boolean'
    end
    if type(opts.max_station_diff) ~= 'number' or opts.max_station_diff < 0 then
        return false, 'max_station_diff must be a non-negative integer'
    end
    self.staged.station_counting = {
        use_station_count = opts.use_station_count,
        max_station_diff  = opts.max_station_diff,
    }
    return true
end

---@param opts BandSetRrmModeOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_rrm_mode(opts)
    if getmetatable(opts) ~= cap_args.BandSetRrmModeOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetRrmModeOpts(opts.mode)
        if not casted then return false, err end
        opts = casted
    end
    if not is_in(opts.mode, VALID_RRM_MODES) then
        return false, 'mode must be one of: ' .. table.concat(VALID_RRM_MODES, ', ')
    end
    self.staged.rrm_mode = opts.mode
    return true
end

---@param opts BandSetNeighbourReportsOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_neighbour_reports(opts)
    if getmetatable(opts) ~= cap_args.BandSetNeighbourReportsOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetNeighbourReportsOpts(opts.dyn_report_num, opts.disassoc_report_len)
        if not casted then return false, err end
        opts = casted
    end
    local dyn = tonumber(opts.dyn_report_num)
    local dis  = tonumber(opts.disassoc_report_len)
    if not dyn or dyn < 0 then
        return false, 'dyn_report_num must be a non-negative integer'
    end
    if not dis or dis < 0 then
        return false, 'disassoc_report_len must be a non-negative integer'
    end
    self.staged.neighbour_reports = {
        dyn_report_num    = dyn,
        disassoc_report_len = dis,
    }
    return true
end

---@param opts BandSetLegacyOptionsOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_legacy_options(opts)
    if getmetatable(opts) ~= cap_args.BandSetLegacyOptionsOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetLegacyOptionsOpts(opts.opts)
        if not casted then return false, err end
        opts = casted
    end
    local legacy_opts = opts.opts
    if type(legacy_opts) ~= 'table' then
        return false, 'opts.opts must be a table'
    end
    if not self.staged.legacy then self.staged.legacy = {} end
    for key, value in pairs(legacy_opts) do
        if not is_in(key, VALID_LEGACY_KEYS) then
            return false, 'unknown legacy option key: ' .. tostring(key)
        end
        if value == nil then
            return false, 'nil value for legacy option: ' .. key
        end
        self.staged.legacy[key] = value
    end
    return true
end

---@param opts BandSetBandPriorityOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_band_priority(opts)
    if getmetatable(opts) ~= cap_args.BandSetBandPriorityOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetBandPriorityOpts(opts.band, opts.priority)
        if not casted then return false, err end
        opts = casted
    end
    local band = type(opts.band) == 'string' and opts.band:upper() or ''
    if not is_in(band, VALID_BANDS) then
        return false, 'band must be "2G" or "5G"'
    end
    if type(opts.priority) ~= 'number' or opts.priority < 0 then
        return false, 'priority must be a non-negative number'
    end
    if not self.staged.band_priorities then self.staged.band_priorities = {} end
    self.staged.band_priorities[band] = { initial_score = opts.priority }
    return true
end

---@param opts BandSetBandKickingOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_band_kicking(opts)
    if getmetatable(opts) ~= cap_args.BandSetBandKickingOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetBandKickingOpts(opts.band, opts.options)
        if not casted then return false, err end
        opts = casted
    end
    local band = type(opts.band) == 'string' and opts.band:upper() or ''
    if not is_in(band, VALID_BANDS) then
        return false, 'band must be "2G" or "5G"'
    end
    if type(opts.options) ~= 'table' then
        return false, 'options must be a table'
    end
    if not self.staged.band_kicking then self.staged.band_kicking = {} end
    if not self.staged.band_kicking[band] then self.staged.band_kicking[band] = {} end
    for key, value in pairs(opts.options) do
        if not is_in(key, VALID_BAND_KICKING_OPTS) then
            return false, 'unknown band kicking option: ' .. tostring(key)
        end
        local n = tonumber(value)
        if n == nil then
            return false, 'value for ' .. key .. ' must be a number'
        end
        self.staged.band_kicking[band][key] = n
    end
    return true
end

---@param opts BandSetSupportBonusOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_support_bonus(opts)
    if getmetatable(opts) ~= cap_args.BandSetSupportBonusOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetSupportBonusOpts(opts.band, opts.support, opts.reward)
        if not casted then return false, err end
        opts = casted
    end
    local band = type(opts.band) == 'string' and opts.band:upper() or ''
    if not is_in(band, VALID_BANDS) then
        return false, 'band must be "2G" or "5G"'
    end
    if not is_in(opts.support, VALID_SUPPORTS) then
        return false, 'support must be "ht" or "vht"'
    end
    if type(opts.reward) ~= 'number' then
        return false, 'reward must be a number'
    end
    if not self.staged.support_bonus then self.staged.support_bonus = {} end
    if not self.staged.support_bonus[band] then self.staged.support_bonus[band] = {} end
    self.staged.support_bonus[band][opts.support] = opts.reward
    return true
end

---@param opts BandSetUpdateFreqOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_update_freq(opts)
    if getmetatable(opts) ~= cap_args.BandSetUpdateFreqOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetUpdateFreqOpts(opts.updates)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.updates) ~= 'table' then
        return false, 'updates must be a table'
    end
    if not self.staged.update_freq then self.staged.update_freq = {} end
    for key, value in pairs(opts.updates) do
        if not is_in(key, VALID_UPDATE_KEYS) then
            return false, 'unknown update key: ' .. tostring(key)
        end
        if type(value) ~= 'number' or value < 0 then
            return false, 'value for ' .. key .. ' must be a non-negative number'
        end
        self.staged.update_freq[key] = value
    end
    return true
end

---@param opts BandSetClientInactiveKickoffOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_client_inactive_kickoff(opts)
    if getmetatable(opts) ~= cap_args.BandSetClientInactiveKickoffOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetClientInactiveKickoffOpts(opts.timeout)
        if not casted then return false, err end
        opts = casted
    end
    local timeout = tonumber(opts.timeout)
    if not timeout or timeout < 0 then
        return false, 'timeout must be a non-negative integer'
    end
    self.staged.con_timeout = timeout
    return true
end

---@param opts BandSetCleanupOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_cleanup(opts)
    if getmetatable(opts) ~= cap_args.BandSetCleanupOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetCleanupOpts(opts.timeouts)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.timeouts) ~= 'table' then
        return false, 'timeouts must be a table'
    end
    if not self.staged.cleanup then self.staged.cleanup = {} end
    for key, value in pairs(opts.timeouts) do
        if not is_in(key, VALID_CLEANUP_KEYS) then
            return false, 'unknown cleanup key: ' .. tostring(key)
        end
        if type(value) ~= 'number' or value < 0 then
            return false, 'value for cleanup.' .. key .. ' must be a non-negative number'
        end
        self.staged.cleanup[key] = value
    end
    return true
end

---@param opts BandSetNetworkingOpts
---@return boolean ok
---@return string? reason
function BandDriver:set_networking(opts)
    if getmetatable(opts) ~= cap_args.BandSetNetworkingOpts then
        opts = opts or {}
        local casted, err = cap_args.new.BandSetNetworkingOpts(opts.method, opts.options)
        if not casted then return false, err end
        opts = casted
    end
    if not is_in(opts.method, VALID_NETWORKING_METHODS) then
        return false, 'method must be one of: ' .. table.concat(VALID_NETWORKING_METHODS, ', ')
    end
    if type(opts.options) ~= 'table' then
        return false, 'options must be a table'
    end

    local net = { method = opts.method }
    for key, value in pairs(opts.options) do
        if not is_in(key, VALID_NETWORKING_OPTS) then
            return false, 'unknown networking option: ' .. tostring(key)
        end
        if key == 'ip' and type(value) ~= 'string' then
            return false, 'networking.ip must be a string'
        end
        if (key == 'port' or key == 'broadcast_port') and type(value) ~= 'number' then
            return false, 'networking.' .. key .. ' must be a number'
        end
        if key == 'enable_encryption' and type(value) ~= 'boolean' then
            return false, 'networking.enable_encryption must be a boolean'
        end
        net[key] = value
    end
    self.staged.networking = net
    return true
end

---@return boolean ok
---@return string? reason
function BandDriver:apply()
    local ok, err = pcall(function() self.backend:apply(self.staged) end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

---@return boolean ok
---@return string? reason
function BandDriver:clear()
    local ok, err = self.backend:clear()
    if not ok then
        return false, err
    end
    self.staged = {}
    return true
end

---@return boolean ok
function BandDriver:rollback()
    self.staged = {}
    return true
end

------------------------------------------------------------------------
-- Control manager fiber
------------------------------------------------------------------------

function BandDriver:control_manager()
    fibers.current_scope():finally(function()
        self.log:debug({ what = 'band_driver_stopped', id = self.id })
    end)

    while true do
        local name, request = fibers.perform(fibers.named_choice({
            rpc    = self.control_ch:get_op(),
            cancel = fibers.current_scope():cancel_op(),
        }))

        if name == 'cancel' then break end

        local fn = self[request.verb]
        local ok, reason
        if type(fn) ~= 'function' then
            ok, reason = false, 'unknown verb: ' .. tostring(request.verb)
        else
            local call_ok, r1, r2 = pcall(fn, self, request.opts)
            if not call_ok then
                ok, reason = false, tostring(r1)
            else
                ok, reason = r1, r2
            end
        end

        local reply = hal_types.new.Reply(ok, reason)
        if reply then
            request.reply_ch:put(reply)
        end
    end
end

------------------------------------------------------------------------
-- Public driver interface
------------------------------------------------------------------------

---@return string err  empty string on success
function BandDriver:init()
    local ok, err = self.backend:clear()
    if not ok then
        return "band backend clear failed: " .. tostring(err)
    end
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]? caps
---@return string err
function BandDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "driver not initialised"
    end
    if self.caps_applied then
        return nil, "capabilities already applied"
    end
    self.cap_emit_ch = emit_ch

    local cap, cap_err = cap_types.new.Capability(
        'band',
        '1',
        self.control_ch,
        {
            'set_log_level',
            'set_kicking',
            'set_station_counting',
            'set_rrm_mode',
            'set_neighbour_reports',
            'set_legacy_options',
            'set_band_priority',
            'set_band_kicking',
            'set_support_bonus',
            'set_update_freq',
            'set_client_inactive_kickoff',
            'set_cleanup',
            'set_networking',
            'apply',
            'clear',
            'rollback',
        }
    )
    if not cap then
        return nil, cap_err
    end

    self.caps_applied = true
    return { cap }, ""
end

---@return boolean ok
---@return string err
function BandDriver:start()
    if not self.initialised then
        return false, "driver not initialised"
    end
    if not self.caps_applied then
        return false, "capabilities not applied"
    end
    self.scope:spawn(function() self:control_manager() end)
    return true, ""
end

---Create a new BandDriver instance.
---@param logger table
---@return BandDriver? driver
---@return string      err
local function new(logger)
    local bknd, berr = provider.new()
    if not bknd then
        return nil, "no band backend: " .. tostring(berr)
    end

    local scope, serr = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(serr)
    end

    local driver = setmetatable({
        id           = '1',
        scope        = scope,
        control_ch   = channel.new(CONTROL_Q_LEN),
        cap_emit_ch  = nil,
        staged       = {},
        initialised  = false,
        caps_applied = false,
        log          = logger,
        backend      = bknd,
    }, BandDriver)

    return driver, ""
end

return {
    new    = new,
    Driver = BandDriver,
}
