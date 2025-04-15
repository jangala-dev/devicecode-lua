local op = require "fibers.op"
local context = require "fibers.context"
local sleep = require "fibers.sleep"
local service = require "service"
local log = require "log"
local new_msg = require "bus".new_msg
local apn = require "services.gsm.apn"

local gsm_service = {
    name = 'GSM'
}
gsm_service.__index = {}

-- for now we only hold configs about modems but later may need to hold
-- sim and sim switching configs as well
local configs = {
    modem = {
        default = {},
        imei = {},
        device = {}
    }
}

-- store active modems by preferred id field, imei by default
local modems = {
    imei = {},
    device = {},
}

---@class Modem
---@field conn Connection
---@field ctx Context
---@field idx number
---@field imei string
---@field name string
---@field cfg table
local Modem = {}
Modem.__index = Modem

--- Autoconnect function attempts to connect the modem to the network using APNs
--- @param ctx Context
--- @param cutoff number
--- @return any apn
--- @return string? error
function Modem:_apn_connect(ctx, cutoff)
    cutoff = cutoff or 4

    -- Subscribe to various modem information topics on the bus
    local mcc_sub = self.conn:subscribe(
        { 'hal', 'capability', 'modem', self.idx, 'info', 'nas', 'home-network', 'mcc' }
    )
    local mcc_msg, mcc_err = mcc_sub:next_msg_with_context_op(ctx):perform()
    mcc_sub:unsubscribe()

    if mcc_err then return nil, mcc_err end
    local mcc = mcc_msg.payload

    local mnc_sub = self.conn:subscribe(
        { 'hal', 'capability', 'modem', self.idx, 'info', 'nas', 'home-network', 'mnc' }
    )
    local mnc_msg, mnc_err = mnc_sub:next_msg_with_context_op(ctx):perform()
    mnc_sub:unsubscribe()
    if mnc_err then return nil, mnc_err end
    local mnc = mnc_msg.payload

    local imsi_sub = self.conn:subscribe(
        { 'hal', 'capability', 'modem', self.idx, 'info', 'sim', 'properties', 'imsi' }
    )
    local imsi_msg, imsi_err = imsi_sub:next_msg_with_context_op(ctx):perform()
    imsi_sub:unsubscribe()
    if imsi_err then return nil, imsi_err end
    local imsi = imsi_msg.payload

    -- local spn, spn_err = self.modem_capability:get_spn() -- this is needed for giffgaff but for now im not doing it because I don't want to
    local spn = nil

    local gid1_sub = self.conn:subscribe(
        { 'hal', 'capability', 'modem', self.idx, 'info', 'gids', 'gid1' }
    )
    local gid1_msg, gid1_err = gid1_sub:next_msg_with_context_op(ctx):perform()
    gid1_sub:unsubscribe()
    if gid1_err then return nil, gid1_err end
    local gid1 = gid1_msg.payload

    -- todo: how to feed apns from configs into this fiber?
    -- (this fiber cannot directly access memory from the gsm_manager)

    local status_sub = self.conn:subscribe(
        { 'hal', 'capability', 'modem', self.idx, 'info', 'state' }
    )

    -- get apns by rank and iterate through all apns within rank requirements
    -- attempt connection on each apn
    local apns, ranks = apn.get_ranked_apns(mcc, mnc, imsi, spn, gid1)
    for _, n in ipairs(ranks) do
        if n.rank > cutoff then break end
        local apn_connect_string, string_err = apn.build_connection_string(apns[n.name], self.cfg.roaming_allow)
        if string_err == nil then
            local connect_sub = self.conn:request(new_msg(
                { 'hal', 'capability', 'modem', self.idx, 'control', 'connect' },
                { apn_connect_string }
            ))
            local connect_msg, ctx_err = connect_sub:next_msg_with_context_op(ctx):perform()
            if ctx_err then
                log.debug(ctx_err); return
            end
            local connect_err = connect_msg.payload.err
            if connect_err == nil then
                status_sub:unsubscribe()
                return apns[n.name], nil
            else
                if string.find(connect_msg.payload.result, "pdn-ipv4-call-throttled") then
                    status_sub:unsubscribe()
                    return nil, "pdn-ipv4-call-throttled"
                end
            end

            -- need to wait for current connection attempt to finish before trying another
            local modem_status = 'connecting'
            while modem_status == 'connecting' do
                local status_msg, status_err = status_sub:next_msg_with_context_op(ctx):perform()
                if status_err then
                    log.debug(status_err); return
                end
                modem_status = status_msg.payload.curr_state
            end
        end
    end
    status_sub:unsubscribe()
    return nil, "no apn connected"
end

---Retrieve and publish the network interface to the bus
---@param ctx Context
---@return string?
function Modem:_publish_iface(ctx)
    local net_iface_sub = self.conn:subscribe(
        { 'hal', 'capability', 'modem', self.idx, 'info', 'modem', 'generic', 'ports', '+' }
    )
    -- the bus handles multiple publish for lists as having numbered endpoints
    -- iterate over all numbered endpoints of ports and check which one holds the net iface; if any
    -- only breaks if iface is found, otherwise errors out
    local net_interface
    while true do
        local net_interface_msg, interface_err = net_iface_sub:next_msg_with_context_op(
            context.with_timeout(ctx, 1)
        ):perform()
        if interface_err then
            net_iface_sub:unsubscribe()
            return interface_err
        end
        net_interface = net_interface_msg.payload:match("%s*(%S+)%s%(net%)")
        if net_interface then break end
    end
    net_iface_sub:unsubscribe()

    self.conn:publish(new_msg(
        { 'gsm', 'modem', self.name, 'interface' },
        net_interface,
        { retained = true }
    ))
end

---Connect modem and set signal report frequency
---@param ctx Context
---@return string?
function Modem:_connect(ctx)
    local active_apn, apn_err = self:_apn_connect(ctx)
    if apn_err then
        if apn_err == "pdn-ipv4-call-throttled" then
            sleep.sleep(360) -- cooldown for 6 minutes before trying again
        else
            sleep.sleep(20)  -- cooldown for 20 seconds before trying again
        end
        return apn_err
    end

    log.info(string.format(
        "%s - %s: CONNECTED",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
    local signal_freq = self.cfg.signal_freq or 5
    local signal_sub = self.conn:request(new_msg(
        { 'hal', 'capability', 'modem', self.idx, 'control', 'set_signal_update_freq' },
        { signal_freq }
    ))
    local result, ctx_err = signal_sub:next_msg_with_context_op(ctx):perform()
    signal_sub:unsubscribe()
    if ctx_err then return ctx_err end
    local signal_update_err = result.payload.err
    if signal_update_err then return signal_update_err end

    self.cfg.apn = active_apn
end

---Enable the modem
---@param ctx Context
---@return string?
function Modem:_enable(ctx)
    local enable_sub = self.conn:request(new_msg(
        { 'hal', 'capability', 'modem', self.idx, 'control', 'enable' },
        {}
    ))
    local ret_msg, ctx_err = enable_sub:next_msg_with_context_op(ctx):perform()
    enable_sub:unsubscribe()
    if ctx_err then return ctx_err end

    local enable_err = ret_msg.payload.err
    if enable_err then return enable_err end
end

---Start warm swap to detect sim insertion
---@param ctx any
---@return string?
function Modem:_detect_sim(ctx)
    local sim_detect_sub = self.conn:request(new_msg(
        { 'hal', 'capability', 'modem', self.idx, 'control', 'sim_detect' },
        {}
    ))
    -- this will return a successful dispatch of a detect command, but not if the sim has actually been detected,
    -- for that we must listen to the state change
    local ret_msg, ctx_err = sim_detect_sub:next_msg_with_context_op(ctx):perform()
    sim_detect_sub:unsubscribe()
    if ctx_err then return ctx_err end

    local sim_err = ret_msg.payload.err
    if sim_err then return sim_err end
end

---Move a modem out of failed state
---@param ctx Context
---@return string?
function Modem:_fix_failure(ctx)
    local fix_failure_sub = self.conn:request(new_msg(
        { 'hal', 'capability', 'modem', self.idx, 'control', 'fix_failure' },
        {}
    ))
    -- this will return a successful dispatch of a fix_failure command, but not if the failure has actually
    -- been fixed, for that we must listen to the state change
    local ret_msg, ctx_err = fix_failure_sub:next_msg_with_context_op(ctx):perform()
    fix_failure_sub:unsubscribe()
    if ctx_err then return ctx_err end

    local fix_err = ret_msg.payload.err
    if fix_err then return fix_err end
end

function Modem:_autounlock(ctx)
    return "not implemented"
end

---State machine to automatically connect the modem to an apn and network interface
---@param ctx Context
function Modem:_autoconnect(ctx)
    log.trace(string.format(
        "%s - %s: Started",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
    local states = {
        locked = self._autounlock,
        failed = self._fix_failure,
        no_sim = self._detect_sim,
        disabled = self._enable,
        registered = self._connect,
        connected = self._publish_iface
    }

    local state_monitor_sub = self.conn:subscribe(
        { 'hal', 'capability', 'modem', self.idx, 'info', 'state' }
    )
    while not ctx:err() do
        local state_info_msg, monitor_err = state_monitor_sub:next_msg_with_context_op(ctx):perform()
        if monitor_err then
            log.debug(monitor_err)
            return
        end
        local state_info = state_info_msg.payload
        log.trace(string.format(
            "%s - %s: State recieved: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            state_info.curr_state
        ))

        -- Get the relavent function to transition to the next state, if any
        local state_func = states[state_info.curr_state]
        if state_func then
            -- Call the state function and check for errors
            local state_err = state_func(self, ctx)
            if state_err then
                log.error(string.format(
                    "%s - %s: State function for state %s failed, reason: %s",
                    ctx:value("service_name"),
                    ctx:value("fiber_name"),
                    state_info.curr_state,
                    state_err
                ))
            end
        end
    end
    state_monitor_sub:unsubscribe()
    log.trace(string.format(
        "%s - %s: Closing, reason: '%s'",
        ctx:value("service_name"),
        ctx:value("fiber_name"),
        ctx:err()
    ))
end

--- Either starts or ends autoconnection and updates modem name
--- @param config table
function Modem:update_config(config)
    self.cfg = config

    -- every modem is initialised with a name either from config or from the imei
    self.name = self.cfg.name or self.imei
    -- stop autoconnect if it is enabled and the new config is disabled
    if config.autoconnect == false and self.autoconnect_ctx and not self.autoconnect_ctx:err() then
        self.autoconnect_ctx:cancel()
        -- start autoconnect if it is disabled and the new config is enabled
    elseif config.autoconnect == true and (not self.autoconnect_ctx or self.autoconnect_ctx:err()) then
        self.autoconnect_ctx = context.with_cancel(self.ctx)
        service.spawn_fiber(
            string.format("Autoconnect (%s)", self.name),
            self.conn,
            self.autoconnect_ctx,
            function(fiber_ctx)
                self:_autoconnect(fiber_ctx)
            end
        )
    end
end

--- Creates a New Modem Capability Class
---@param ctx Context
---@param conn Connection
---@param imei string
---@param index number
---@return Modem
local function new_modem(ctx, conn, imei, index)
    local self = setmetatable({}, Modem)
    self.ctx = context.with_cancel(ctx)
    self.conn = conn

    self.idx = index
    self.imei = imei

    return self
end

--- Create or Destroy a Modem Capability
--- @param ctx Context
--- @param conn Connection Bus Connection
--- @param modem_capability_msg table modem capability infos
local function modem_capability_handler(ctx, conn, modem_capability_msg)
    if modem_capability_msg == nil then return end

    -- get imei and device (port) info from bus
    local modem_imei_sub = conn:subscribe({ 'hal', 'capability', 'modem', modem_capability_msg.index, 'info',
        'modem', 'generic', 'equipment-identifier' })
    local imei_msg, imei_err = modem_imei_sub:next_msg_with_context_op(ctx):perform()
    modem_imei_sub:unsubscribe()
    if imei_err then
        log.error(imei_err); return
    end
    local imei = imei_msg.payload

    local modem_device_sub = conn:subscribe({ 'hal', 'capability', 'modem', modem_capability_msg.index, 'info',
        'modem', 'generic', 'device' })
    local device_msg, device_err = modem_device_sub:next_msg_with_context_op(ctx):perform()
    modem_device_sub:unsubscribe()
    if device_err then
        log.error(device_err); return
    end
    local device = device_msg.payload

    -- get the modem config from the configs table, if not found use default
    local modem_config = configs.modem.imei[imei] or configs.modem.device[device]
    local id_field, key
    if modem_config then
        id_field = modem_config.id_field
        key = modem_config[id_field]
    else
        -- default modems will be stored by imei
        id_field = 'imei'
        key = imei
        modem_config = configs.modem.default
    end

    if modem_capability_msg.connected then
        local modem = new_modem(ctx, conn, imei, modem_capability_msg.index)
        modem:update_config(modem_config)
        modems[id_field][key] = modem
        log.info(string.format('Modem Capability %s detected', modem_capability_msg.index))
    else
        if modems[id_field][key] then
            modems[id_field][key].ctx:cancel('modem disconnected')
            modems[id_field][key] = nil
            log.info(string.format('Modem Capability %s removed', modem_capability_msg.index))
        end
    end
end

--- Merge custom config with default to avoid any missing fields
---@param config table custom config
---@param defaults table default config
local function apply_defaults(config, defaults)
    if not defaults then return end
    for k, v in pairs(defaults) do
        if config[k] == nil then
            config[k] = v
        end
    end
end

--- Applies configs to modems and updates the configs table
---@param config_msg table
local function config_handler(config_msg)
    log.trace("GSM received config")
    if config_msg and config_msg.payload then
        local modem_configs = config_msg.payload.modems
        local default_config = modem_configs.default
        if not default_config then
            log.error("GSM - Config: default config not set")
            return
        end
        configs.modem.default = default_config

        for name, known_config in pairs(modem_configs.known) do
            local id_field = known_config.id_field
            if id_field then
                apply_defaults(known_config, default_config)
                known_config.name = name
                configs.modem[id_field][known_config[id_field]] = known_config

                if modems[id_field][known_config[id_field]] then
                    modems[id_field][known_config[id_field]]:update_config(known_config)
                end
            else
                log.error('GSM - Config: id_field is not set')
            end
        end

        for _, modem in ipairs(modems.imei) do
            if not modem.cfg.name then
                modem:update_config(default_config)
            end
        end
    end
end

--- Manages creation/removal of modem capabilities and application of configs
---@param ctx Context
---@param conn Connection Bus Connection
local function gsm_manager(ctx, conn)
    local capability_sub = conn:subscribe({ 'hal', 'capability', 'modem', '+' })
    local config_sub = conn:subscribe({ 'config', 'gsm' })

    -- load config before anything else
    local config, config_err = config_sub:next_msg_with_context_op(ctx):perform()
    if config_err then
        log.trace(config_err)
        config_sub:unsubscribe()
        capability_sub:unsubscribe()
        return
    end
    config_handler(config)

    while not ctx:err() do
        op.choice(
            capability_sub:next_msg_op():wrap(function(capability_msg)
                modem_capability_handler(ctx, conn, capability_msg.payload)
            end
            ),
            config_sub:next_msg_op():wrap(config_handler),
            ctx:done_op()
        ):perform()
    end
    capability_sub:unsubscribe()
    config_sub:unsubscribe()
    log.trace(string.format("GSM: Manager Closing, reason: '%s'", ctx:err()))
end

--- Initialise GSM service
---@param ctx Context
---@param conn Connection Bus Connection
function gsm_service:start(ctx, conn)
    log.trace("Starting GSM Service")
    service.spawn_fiber('GSM fiber', conn, ctx, function(fiber_ctx)
        gsm_manager(fiber_ctx, conn)
    end)
end

return gsm_service
