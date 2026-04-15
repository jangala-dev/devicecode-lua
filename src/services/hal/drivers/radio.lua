local hal_types  = require "services.hal.types.core"
local cap_types  = require "services.hal.types.capabilities"
local provider   = require "services.hal.backends.radio.provider"
local cap_args   = require "services.hal.types.capability_args"

local fibers  = require "fibers"
local channel = require "fibers.channel"
local sleep   = require "fibers.sleep"

local CONTROL_Q_LEN        = 16
local DEFAULT_REPORT_PERIOD = 60  -- seconds
local INT32_MAX             = 2147483647

local VALID_BANDS = { '2g', '5g' }
local VALID_HTMODES = {
    'HE20', 'HE40+', 'HE40-', 'HE80', 'HE160',
    'HT20', 'HT40+', 'HT40-',
    'VHT20', 'VHT40+', 'VHT40-', 'VHT80', 'VHT160',
}
local VALID_ENCRYPTIONS = {
    'none', 'wep', 'psk', 'psk2', 'psk-mixed',
    'sae', 'sae-mixed', 'owe', 'wpa', 'wpa2', 'wpa3',
}
local VALID_MODES = { 'ap', 'sta', 'adhoc', 'mesh', 'monitor' }

local function is_in(value, list)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

local function is_list(t)
    if type(t) ~= 'table' then return false end
    local i = 1
    for k in pairs(t) do
        if k ~= i then return false end
        i = i + 1
    end
    return true
end

local function fix_underflow(n)
    if type(n) == 'number' and n > INT32_MAX then
        return n - 4294967296
    end
    return n
end

---@class RadioDriver
---@field id string             UCI radio section name
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field staged table          In-memory staged config
---@field iface_counter number  Counter for auto-named interfaces
---@field report_period_ch Channel
---@field initialised boolean
---@field caps_applied boolean
---@field log table
---@field backend table
local RadioDriver = {}
RadioDriver.__index = RadioDriver

local function emit_event(emit_ch, id, key, data)
    local payload = hal_types.new.Emit('radio', id, 'event', key, data)
    if payload then emit_ch:put(payload) end
end

local function emit_state(emit_ch, id, key, data)
    local payload = hal_types.new.Emit('radio', id, 'state', key, data)
    if payload then emit_ch:put(payload) end
end

------------------------------------------------------------------------
-- RPC handler methods (called by control_manager)
------------------------------------------------------------------------

---@param opts RadioSetChannelsOpts
---@return boolean ok
---@return string? reason
function RadioDriver:set_channels(opts)
    if getmetatable(opts) ~= cap_args.RadioSetChannelsOpts then
        opts = opts or {}
        local casted, err = cap_args.new.RadioSetChannelsOpts(opts.band, opts.channel, opts.htmode, opts.channels)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.band) ~= 'string' or not is_in(opts.band, VALID_BANDS) then
        return false, 'band must be one of: ' .. table.concat(VALID_BANDS, ', ')
    end
    if type(opts.htmode) ~= 'string' or not is_in(opts.htmode, VALID_HTMODES) then
        return false, 'htmode must be one of: ' .. table.concat(VALID_HTMODES, ', ')
    end
    if opts.channel == 'auto' then
        if not is_list(opts.channels) or #opts.channels == 0 then
            return false, 'channels must be a non-empty list when channel is "auto"'
        end
    elseif type(opts.channel) ~= 'number' and type(opts.channel) ~= 'string' then
        return false, 'channel must be a number, string, or "auto"'
    end

    self.staged.band    = opts.band
    self.staged.channel = opts.channel
    self.staged.htmode  = opts.htmode
    self.staged.channels = (opts.channel == 'auto') and opts.channels or nil
    return true
end

---@param opts RadioSetTxpowerOpts
---@return boolean ok
---@return string? reason
function RadioDriver:set_txpower(opts)
    if getmetatable(opts) ~= cap_args.RadioSetTxpowerOpts then
        opts = opts or {}
        local casted, err = cap_args.new.RadioSetTxpowerOpts(opts.txpower)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.txpower) ~= 'number' and type(opts.txpower) ~= 'string' then
        return false, 'txpower must be a number or string'
    end
    self.staged.txpower = opts.txpower
    return true
end

---@param opts RadioSetCountryOpts
---@return boolean ok
---@return string? reason
function RadioDriver:set_country(opts)
    if getmetatable(opts) ~= cap_args.RadioSetCountryOpts then
        opts = opts or {}
        local casted, err = cap_args.new.RadioSetCountryOpts(opts.country)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.country) ~= 'string' or #opts.country ~= 2 then
        return false, 'country must be a 2-character string'
    end
    self.staged.country = opts.country:upper()
    return true
end

---@param opts RadioSetEnabledOpts
---@return boolean ok
---@return string? reason
function RadioDriver:set_enabled(opts)
    if getmetatable(opts) ~= cap_args.RadioSetEnabledOpts then
        opts = opts or {}
        local casted, err = cap_args.new.RadioSetEnabledOpts(opts.enabled)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.enabled) ~= 'boolean' then
        return false, 'enabled must be a boolean'
    end
    -- UCI disabled flag is inverted
    self.staged.disabled = opts.enabled and '0' or '1'
    return true
end

---@param opts RadioAddInterfaceOpts
---@return boolean ok
---@return string? iface_name  generated interface name on success
function RadioDriver:add_interface(opts)
    if getmetatable(opts) ~= cap_args.RadioAddInterfaceOpts then
        opts = opts or {}
        local casted, err = cap_args.new.RadioAddInterfaceOpts(
            opts.ssid, opts.encryption, opts.password, opts.network, opts.mode, opts.enable_steering)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.ssid) ~= 'string' or opts.ssid == '' then
        return false, 'ssid must be a non-empty string'
    end
    if type(opts.encryption) ~= 'string' or not is_in(opts.encryption, VALID_ENCRYPTIONS) then
        return false, 'encryption must be one of: ' .. table.concat(VALID_ENCRYPTIONS, ', ')
    end
    if type(opts.password) ~= 'string' then
        return false, 'password must be a string'
    end
    if type(opts.network) ~= 'string' or opts.network == '' then
        return false, 'network must be a non-empty string'
    end
    if type(opts.mode) ~= 'string' or not is_in(opts.mode, VALID_MODES) then
        return false, 'mode must be one of: ' .. table.concat(VALID_MODES, ', ')
    end
    if type(opts.enable_steering) ~= 'boolean' then
        return false, 'enable_steering must be a boolean'
    end

    local iface_name = self.id .. '_i' .. tostring(self.iface_counter)
    self.iface_counter = self.iface_counter + 1

    table.insert(self.staged.interfaces, {
        name            = iface_name,
        ssid            = opts.ssid,
        encryption      = opts.encryption,
        password        = opts.password,
        network         = opts.network,
        mode            = opts.mode,
        enable_steering = opts.enable_steering,
    })
    -- Reply carries the generated interface name in reason
    return true, iface_name
end

---@param opts RadioDeleteInterfaceOpts
---@return boolean ok
---@return string? reason
function RadioDriver:delete_interface(opts)
    if getmetatable(opts) ~= cap_args.RadioDeleteInterfaceOpts then
        opts = opts or {}
        local casted, err = cap_args.new.RadioDeleteInterfaceOpts(opts.interface)
        if not casted then return false, err end
        opts = casted
    end
    if type(opts.interface) ~= 'string' or opts.interface == '' then
        return false, 'interface must be a non-empty string'
    end
    -- Remove from staged interfaces list
    for i, iface in ipairs(self.staged.interfaces) do
        if iface.name == opts.interface then
            table.remove(self.staged.interfaces, i)
            table.insert(self.staged.deleted_interfaces, opts.interface)
            return true
        end
    end
    return false, 'interface not found in staged config: ' .. opts.interface
end

---@return boolean ok
function RadioDriver:clear_radio_config()
    self.staged = {
        name               = self.id,
        path               = self.staged.path,
        type               = self.staged.type,
        interfaces         = {},
        deleted_interfaces = {},
    }
    return true
end

---@param opts RadioSetReportPeriodOpts
---@return boolean ok
---@return string? reason
function RadioDriver:set_report_period(opts)
    if getmetatable(opts) ~= cap_args.RadioSetReportPeriodOpts then
        opts = opts or {}
        local casted, err = cap_args.new.RadioSetReportPeriodOpts(opts.period)
        if not casted then return false, err end
        opts = casted
    end
    local period = opts.period
    if type(period) ~= 'number' or period <= 0 then
        return false, 'period must be a positive number'
    end
    self.report_period_ch:put(period)
    return true
end

---@return boolean ok
---@return string? reason
function RadioDriver:apply()
    local ok, err = pcall(self.backend.apply, self.staged)
    if not ok then
        return false, tostring(err)
    end
    -- Reset interface counter on successful apply
    self.iface_counter = 0
    return true
end

---@return boolean ok
function RadioDriver:rollback()
    self.staged = {
        name               = self.id,
        path               = self.staged.path,
        type               = self.staged.type,
        interfaces         = {},
        deleted_interfaces = {},
    }
    self.iface_counter = 0
    return true
end

------------------------------------------------------------------------
-- Control manager fiber
------------------------------------------------------------------------

function RadioDriver:control_manager()
    fibers.current_scope():finally(function()
        self.log:debug({ what = 'radio_driver_stopped', id = self.id })
    end)

    while true do
        local request = fibers.perform(fibers.named_choice({
            rpc    = self.control_ch:get_op(),
            cancel = fibers.current_scope():cancel_op(),
        }))

        if not request then break end  -- scope cancelled, request is nil

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
-- Stats loop fiber
------------------------------------------------------------------------

function RadioDriver:stats_loop()
    local emit_ch      = self.cap_emit_ch
    local id           = self.id
    local report_period = DEFAULT_REPORT_PERIOD
    local backend       = self.backend

    -- Track connected stations: { [iface] = { [mac] = true } }
    local connected = {}

    -- Collect all interface names from staged config at start
    -- (interfaces are populated by the time start() is called)
    local function get_interfaces()
        local result = {}
        for _, iface in ipairs(self.staged.interfaces) do
            table.insert(result, iface.name)
        end
        return result
    end

    -- Client event callback channel (watch_events calls cb in its fiber)
    local event_ch = channel.new(32)

    -- Spawn the event watcher as a child fiber
    local interfaces = get_interfaces()
    fibers.current_scope():spawn(function()
        backend.watch_events(interfaces, function(ev)
            event_ch:put(ev)
        end)
    end)

    local tick_ch = channel.new(1)
    fibers.current_scope():spawn(function()
        while true do
            fibers.perform(sleep.sleep_op(report_period))
            tick_ch:put(true)
        end
    end)

    fibers.current_scope():finally(function()
        self.log:debug({ what = 'radio_stats_loop_stopped', id = id })
    end)

    while true do
        local name, val = fibers.perform(fibers.named_choice({
            client_event  = event_ch:get_op(),
            tick          = tick_ch:get_op(),
            new_period    = self.report_period_ch:get_op(),
            cancel        = fibers.current_scope():cancel_op(),
        }))

        if name == 'cancel' then
            break

        elseif name == 'new_period' then
            report_period = val

        elseif name == 'client_event' then
            local ev = val
            local mac       = ev.mac
            local iface     = ev.interface
            local timestamp = os.time()

            if not connected[iface] then connected[iface] = {} end

            if ev.connected then
                connected[iface][mac] = true
            else
                connected[iface][mac] = nil
            end

            emit_event(emit_ch, id, 'client_event', {
                mac       = mac,
                connected = ev.connected,
                interface = iface,
                timestamp = timestamp,
            })

            -- Emit updated station counts
            local total = 0
            for _, macs in pairs(connected) do
                for _ in pairs(macs) do total = total + 1 end
            end
            emit_state(emit_ch, id, 'num_sta', total)

            local iface_list = get_interfaces()
            for idx, iface_name in ipairs(iface_list) do
                local count = 0
                if connected[iface_name] then
                    for _ in pairs(connected[iface_name]) do count = count + 1 end
                end
                emit_state(emit_ch, id, 'iface_num_sta', {
                    interface = iface_name,
                    index     = idx - 1,
                    count     = count,
                })
            end

        elseif name == 'tick' then
            local iface_list = get_interfaces()
            for _, iface_name in ipairs(iface_list) do

                -- Interface info (txpower, channel, freq, width)
                local info, _ = backend.get_iface_info(iface_name)
                if info then
                    if info.txpower ~= nil then
                        emit_state(emit_ch, id, 'iface_txpower', {
                            interface = iface_name,
                            value     = fix_underflow(info.txpower),
                        })
                    end
                    if info.channel ~= nil then
                        emit_state(emit_ch, id, 'iface_channel', {
                            interface = iface_name,
                            channel   = info.channel,
                            freq      = info.freq,
                            width     = info.width,
                        })
                    end
                end

                -- Survey noise
                local noise, _ = backend.get_iface_survey(iface_name)
                if noise ~= nil then
                    emit_state(emit_ch, id, 'iface_noise', {
                        interface = iface_name,
                        value     = fix_underflow(noise),
                    })
                end

                -- sysfs network counters
                for _, stat in ipairs(backend.SYSFS_STATS or {}) do
                    local sval, _ = backend.read_sysfs_stat(iface_name, stat)
                    if sval ~= nil then
                        emit_state(emit_ch, id, 'iface_' .. stat, {
                            interface = iface_name,
                            value     = fix_underflow(sval),
                        })
                    end
                end

                -- Per-client stats
                if connected[iface_name] then
                    for mac in pairs(connected[iface_name]) do
                        local sta, _ = backend.get_station_info(iface_name, mac)
                        if sta then
                            if sta.signal ~= nil then
                                emit_state(emit_ch, id, 'client_signal', {
                                    mac       = mac,
                                    interface = iface_name,
                                    signal    = fix_underflow(sta.signal),
                                })
                            end
                            if sta.tx_bytes ~= nil then
                                emit_state(emit_ch, id, 'client_tx_bytes', {
                                    mac       = mac,
                                    interface = iface_name,
                                    value     = fix_underflow(sta.tx_bytes),
                                })
                            end
                            if sta.rx_bytes ~= nil then
                                emit_state(emit_ch, id, 'client_rx_bytes', {
                                    mac       = mac,
                                    interface = iface_name,
                                    value     = fix_underflow(sta.rx_bytes),
                                })
                            end
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Public driver interface
------------------------------------------------------------------------

---@return string err  empty string on success
function RadioDriver:init()
    local meta, err = self.backend.get_meta(self.id)
    if not meta then
        return "get_meta failed: " .. tostring(err)
    end
    self.staged.path = meta.path
    self.staged.type = meta.type
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]? caps
---@return string err
function RadioDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "driver not initialised"
    end
    if self.caps_applied then
        return nil, "capabilities already applied"
    end
    self.cap_emit_ch = emit_ch

    local cap, cap_err = cap_types.new.Capability(
        'radio',
        self.id,
        self.control_ch,
        {
            'set_channels',
            'set_txpower',
            'set_country',
            'set_enabled',
            'add_interface',
            'delete_interface',
            'clear_radio_config',
            'set_report_period',
            'apply',
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
function RadioDriver:start()
    if not self.initialised then
        return false, "driver not initialised"
    end
    if not self.caps_applied then
        return false, "capabilities not applied"
    end

    self.scope:spawn(function() self:control_manager() end)
    self.scope:spawn(function() self:stats_loop() end)
    return true, ""
end

---Create a new RadioDriver instance.
---@param name string    UCI radio section name (e.g. "radio0")
---@param logger table
---@return RadioDriver? driver
---@return string       err
local function new(name, logger)
    if type(name) ~= 'string' or name == '' then
        return nil, "invalid radio name"
    end

    local bknd, berr = provider.get_backend()
    if not bknd then
        return nil, "no radio backend: " .. tostring(berr)
    end

    local scope, serr = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(serr)
    end

    local driver = setmetatable({
        id               = name,
        scope            = scope,
        control_ch       = channel.new(CONTROL_Q_LEN),
        cap_emit_ch      = nil,
        report_period_ch = channel.new(1),
        staged           = {
            name               = name,
            path               = '',
            type               = '',
            interfaces         = {},
            deleted_interfaces = {},
        },
        iface_counter    = 0,
        initialised      = false,
        caps_applied     = false,
        log              = logger,
        backend          = bknd,
    }, RadioDriver)

    return driver, ""
end

return {
    new    = new,
    Driver = RadioDriver,
}
