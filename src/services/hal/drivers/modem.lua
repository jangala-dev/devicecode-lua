-- driver.lua
local fiber = require "fibers.fiber"
local op = require "fibers.op"
local queue = require "fibers.queue"
local context = require "fibers.context"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local service = require "service"
local at = require "services.hal.drivers.modem.at"
local mmcli = require "services.hal.drivers.modem.mmcli"
local utils = require "services.hal.utils"
local hal_capabilities = require "services.hal.hal_capabilities"
local mode_overrides = require "services.hal.drivers.modem.mode"
local model_overrides = require "services.hal.drivers.modem.model"
local json = require "dkjson"
local log = require "log"
local wraperr = require "wraperr"

local unpack = table.unpack or unpack
local CMD_TIMEOUT = 3

local Driver = {}
Driver.__index = Driver

local model_info = {
    quectel = {
        -- these are ordered, as eg25gl should match before eg25g
        {mod_string = "UNKNOWN", rev_string = "eg25gl", model = "eg25", model_variant = "gl"},
        {mod_string = "UNKNOWN", rev_string = "eg25g", model = "eg25", model_variant = "g"},
        {mod_string = "UNKNOWN", rev_string = "ec25e", model = "ec25", model_variant = "e"},
        {mod_string = "em06-e", rev_string = "em06e", model = "em06", model_variant = "e"},
        {mod_string = "rm520n-gl", rev_string = "rm520ngl", model = "rm520n", model_variant = "gl"}
        -- more quectel models here
    },
    fibocom = {}
}

function Driver:get_capabilities()
    local capabilities = {}
    capabilities.modem = {
        control = hal_capabilities.new_modem_capability(self.command_q),
        info_streams = {
            { name = 'state', channel = self.state_monitor_channel, endpoints = 'single' },
            { name = 'modem', channel = self.modem_info_channel,    endpoints = 'multiple' },
            { name = 'sim',   channel = self.sim_info_channel,      endpoints = 'multiple' },
            { name = 'nas',   channel = self.nas_channel,           endpoints = 'multiple' },
            { name = 'gids',  channel = self.gid_channel,           endpoints = 'multiple' }
        }
    }

    -- local new_ctx = context.with_timeout(self.ctx, CMD_TIMEOUT)
    -- local cmd = mmcli.location_status(new_ctx, self.address)
    -- local out, out_err = cmd:combined_output()
    -- if out_err then return nil, wraperr.new(out_err) end

    -- local location_info, _, decode_err = json.decode(out)
    -- if decode_err then return nil, wraperr.new(decode_err) end

    -- local location_capabilities = location_info.modem.location.capabilities
    -- if #location_capabilities > 0 then
    --     capabilities.gps = {
    --         control = hal_capabilities.new_gps_capability(self.command_q),
    --         info_streams = { { name = 'gps', channel = self.gps_info_channel, endpoints = 'single' } }
    --     }
    -- end

    capabilities.time = {
        control = hal_capabilities.new_time_capability(self.command_q),
        info_streams = {}
    }
    -- add time events

    return capabilities
end
function Driver:poll_info()
    local poll_freq = 1

    while not self.ctx:err() do
        local modem_info, modem_err = self:get_modem_info()
        if modem_err then
            log.error(string.format("Modem - %s: Failed to get modem info: %s", self.imei, modem_err))
        else
            if modem_info.generic.sim ~= '--' then
                local sim_info, sim_err = self:get_sim_info(modem_info.generic.sim)
                if sim_err then
                    log.debug("Sim - %s: Failed to get sim info: %s", self.imei, sim_err)
                else
                    op.choice(
                        self.sim_info_channel:put_op(sim_info),
                        self.ctx:done_op()
                    ):perform()
                end

                if modem_info["3gpp"]["registration-state"] ~= "--" then
                    local nas_info, nas_err = self.get_nas_info()

                    if nas_err then
                        log.debug("MCC MNC failed retrieval", nas_err)
                    end
                    op.choice(
                        self.nas_channel:put_op(nas_info),
                        self.ctx:done_op()
                    ):perform()
                end
            end

            if modem_info.generic.state ~= 'failed' then
                local gids, gid_err = self.uim_get_gids()
                local gid_table = {
                    gid1 = gids.gid1,
                    gid2 = gids.gid2
                }
                if gid_err then log.debug(gid_err) end
                op.choice(
                    self.gid_channel:put_op(gid_table),
                    self.ctx:done_op()
                ):perform()
            end

            op.choice(
                self.modem_info_channel:put_op(modem_info),
                self.ctx:done_op()
            ):perform()
        end
        local poll_freq_update = op.choice(
            self.ctx:done_op(),
            sleep.sleep_op(poll_freq),
            self.refresh_rate_channel:get_op()
        ):perform()
        if poll_freq_update then poll_freq = poll_freq_update end
    end

    log.trace(string.format("Modem - %s: Polling info stopped", self.imei))
end
function Driver:get_modem_info()
    local new_ctx = context.with_timeout(self.ctx, CMD_TIMEOUT)
    local cmd = mmcli.information(new_ctx, self.address)
    local out, err = cmd:combined_output()
    if err then return nil, wraperr.new(err) end

    local info, _, err = json.decode(out)
    if err then return nil, wraperr.new(err) end

    return info.modem, nil
end

function Driver:get_sim_info(sim_address)
    local new_ctx = context.with_timeout(self.ctx, CMD_TIMEOUT)
    local cmd = mmcli.sim_information(new_ctx, sim_address)
    local out, err = cmd:combined_output()
    if err then return nil, wraperr.new(err) end

    local info, _, err = json.decode(out)
    if err then return nil, wraperr.new(err) end

    return info.sim, nil
end
function Driver:init()
    local info, err = self:get_modem_info()
    if info == nil or err then return err end

    -- let's get the driver mode
    local drivers = info.generic.drivers

    for _, v in pairs(drivers) do
        self.mode = v=="qmi_wwan" and "qmi" or v=="cdc_mbim" and "mbim"
        if self.mode then break end
    end

    -- -- now let's enrich the driver with mode specific functions/overrides
    assert(mode_overrides.add_mode_funcs(self))

    -- let's now determine the manufacturer, model and variant
    local plugin = info.generic.plugin

    local model = info.generic.model

    local revision = info.generic.revision

    for man, mods in pairs(model_info) do
        if string.match(plugin:lower(), man) then
            self.manufacturer = man
            for _, details in ipairs(mods) do
                if details.mod_string == model:lower() or utils.starts_with(revision, details.rev_string) then
                    log.info(man, details.model, details.model_variant, "detected at:", self.address)
                    self.model = details.model
                    self.model_variant = details.model_variant
                end
            end
            break
        end
    end

    self.primary_port = string.format('/dev/%s', info.generic["primary-port"])
    self.imei = info.generic['equipment-identifier']
    self.device = info.generic.device
    -- -- we add any make/model specific functions/overrides
    model_overrides.add_model_funcs(self)
end

function Driver:spawn(bus_conn)
    service.spawn_fiber('Modem Info Poll - ' .. self.imei, bus_conn, self.ctx, function()
        self:poll_info()
    end)
    service.spawn_fiber('Modem State Monitor - ' .. self.imei, bus_conn, self.ctx, function(monitor_ctx)
        self:state_monitor(monitor_ctx)
    end)
    service.spawn_fiber('Modem Command Manager - ' .. self.imei, bus_conn, self.ctx, function()
        self:command_manager()
    end)
end
-- Base methods can be defined here
function Driver.set_power_low(ctx)
    local cmd_ctx = context.with_timeout(ctx, 0.3)
    return at.send_with_context(cmd_ctx, "AT+CFUN=0")
end

function Driver.set_power_high(ctx)
    local cmd_ctx = context.with_timeout(ctx, 0.3)
    return at.send_with_context(cmd_ctx, "AT+CFUN=1")
end

function Driver:set_func_flight()
    local cmd_ctx = context.with_timeout(self.ctx, 0.3)
    return at.send_with_context(cmd_ctx, "AT+CFUN=4")
end

function Driver:disable()
    local cmd = mmcli.disable(self.address)
    return cmd:run()
end

function Driver:enable()
    local cmd = mmcli.enable(self.address)
    return cmd:run()
end

function Driver:reset()
    local cmd = mmcli.reset(self.address)
    return cmd:run()
end

function Driver:connect(connection_string)
    local new_ctx = context.with_timeout(self.ctx, CMD_TIMEOUT)
    local cmd = mmcli.connect(new_ctx, self.address, connection_string)
    local out, err = cmd:combined_output()
    return out, err
end

function Driver:disconnect()
    local cmd = mmcli.disconnect(self.address)
    return cmd:run()
end

function Driver:inhibit()
    local cmd = mmcli.inhibit(self.address)
    local err = cmd:start()
    if err then log.trace("inhibit failed"); return false end
    cmd:kill()
    return true
end

function Driver:wait_for_sim()
    if self.waiting_for_sim then return end
    self.waiting_for_sim = true
    local warm_swap_ctx = context.with_cancel(self.ctx)
    local slot_monitor_op, slot_monitor_close, slot_monitor_err = self.monitor_slot_status()

    if slot_monitor_err then
        log.error(string.format(
            "%s - %s: Failed to start for %s, reason: %s",
            warm_swap_ctx:value("service_name"),
            warm_swap_ctx:value("fiber_name"),
            self.imei,
            slot_monitor_err
        ))
        return
    end
    fiber.spawn(function()
        local connected = false
        while not connected do
            local state, parse_err, ctx_err = op.choice(
                slot_monitor_op(),
                warm_swap_ctx:done_op():wrap(function()
                    return nil, nil, self.ctx:err()
                end)
            ):perform()
            if ctx_err then break end
            if parse_err then
                log.debug(string.format(
                    "%s - %s: Failed to parse slot monitor for %s, reason: %s",
                    warm_swap_ctx:value("service_name"),
                    warm_swap_ctx:value("fiber_name"),
                    self.imei,
                    parse_err
                ))
            else
                connected = state
            end
        end
        if connected then
            warm_swap_ctx:cancel()
        end
        slot_monitor_close()
    end)

    sleep.sleep(0.1)

    while not warm_swap_ctx:err() do
        -- this is going to really hammer the modem
        -- without a courtesy sleep
        local lw_out, lw_err = self.set_power_low(warm_swap_ctx)
        if lw_err then
            log.debug(string.format(
                '%s: Failed to set modem power low "%s" (%s) for %s',
                self.ctx:value("service_name"),
                lw_out,
                lw_err,
                self.imei
            ))
        end
        local hg_out, hg_err = self.set_power_high(warm_swap_ctx)
        if hg_err then
            log.debug(string.format(
                '%s: Failed to set modem power high "%s" (%s) for %s',
                self.ctx:value("service_name"),
                hg_out,
                hg_err,
                self.imei
            ))
        end
        sleep.sleep(0.5)
    end
    -- we must attempt to put modem into high power state even if disconnected
    -- as we could otherwise get stuck in a failed state boot-loop
    local out, err = self.set_power_high(context.background())
    if err then
        log.error(string.format(
            '%s: Failed to set modem power high "%s" (%s) for %s',
            self.ctx:value("service_name"),
            out,
            err,
            self.imei
        ))
    end
    self.waiting_for_sim = false
end
function Driver:sim_detect()
    fiber.spawn(function()
        self:wait_for_sim()
    end)
    return true, nil
end

function Driver:fix_failure()
    fiber.spawn(function()
        self:wait_for_sim()
        self:inhibit()
    end)
    return true, nil
end

function Driver:set_signal_update_freq(seconds)
    local cmd = mmcli.signal_setup(self.ctx, self.address, seconds)
    local cmd_err = cmd:run()
    self.refresh_rate_channel:put(seconds)
    return (cmd_err == nil), cmd_err
end

function modem_states_equal(state1, state2)
    return state1.curr_state == state2.curr_state and
        state1.prev_state == state2.prev_state and
        state1.reason == state2.reason
end

function Driver:state_monitor(ctx)
    if ctx:err() then return end
    log.trace(string.format(
        "%s - %s: Started for %s",
        ctx:value("service_name"),
        ctx:value("fiber_name"),
        self.imei
    ))

    -- setup the modem monitor
    local modem_monitor_cmd = mmcli.monitor_state(self.address)
    local stdout = assert(modem_monitor_cmd:stdout_pipe())
    local cmd_err = modem_monitor_cmd:start()
    if cmd_err then
        log.error(string.format(
            "%s - %s: Failed to start for %s, reason: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            self.imei,
            cmd_err
        ))
        return
    end

    -- setup the sim monitor
    local sim_monitor_op, sim_close_op, sim_monitor_err = self.monitor_slot_status()
    if sim_monitor_err then
        log.error(string.format(
            "%s - %s: Failed to start for %s, reason: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            self.imei,
            sim_monitor_err
        ))
        return
    end

    local prev_modem_state = {}
    local modem_state
    local sim_connected = self.is_sim_inserted()
    while not ctx:err() do
        local line_err, ctx_err = op.choice(
            stdout:read_line_op():wrap(function(line)
                -- not sure about doing this tbh
                if line == nil then return 'line was nil' end
                local modem_line, err = utils.parse_modem_monitor(line)
                if err then return err end
                modem_state = modem_line
            end),
            sim_monitor_op():wrap(function(connected, err)
                if err then return err .. " " .. tostring(connected) end
                sim_connected = connected
            end),
            ctx:done_op():wrap(function()
                return nil, ctx:err()
            end)
        ):perform()
        if ctx_err then break end

        if line_err then
            log.debug(line_err)
        else
            if sim_connected == false and modem_state.curr_state ~= 'failed' then
                modem_state.curr_state = 'no_sim'
            end
            -- only publish if state has changed
            if not modem_states_equal(modem_state, prev_modem_state) then
                self.state_monitor_channel:put(modem_state)
                prev_modem_state = modem_state
            end
        end
    end
    -- clean up
    modem_monitor_cmd:kill()
    stdout:close()
    sim_close_op()
    log.trace(string.format(
        "%s - %s: Closed for %s, reason: %s",
        ctx:value("service_name"),
        ctx:value("fiber_name"),
        self.imei,
        ctx:err()
    ))
end

function Driver:command_manager()
    log.trace(string.format("Modem - %s: Command Manager started", self.imei))
    while not self.ctx:err() do
        local cmd_msg = op.choice(
            self.command_q:get_op(),
            self.ctx:done_op()
        ):perform()


        if cmd_msg ~= nil then
            local cmd = self[cmd_msg.command]
            local ret, err = nil, 'command does not exist'
            if cmd ~= nil then
                local args = cmd_msg.args or {}
                ret, err = cmd(self, unpack(args))
            end

            fiber.spawn(function()
                op.choice(
                    cmd_msg.return_channel:put_op({ result = ret, err = err }),
                    self.ctx:done_op()
                ):perform()
            end)
        end
    end
    log.trace(string.format("Modem - %s: Command Manager stopped (%s)", self.imei, self.ctx:err()))
end


local function new(ctx, address)
    local self = setmetatable({}, Driver)
    self.ctx = ctx
    self.address = address
    self.command_q = queue.new()
    self.state_monitor_channel = channel.new()
    self.modem_info_channel = channel.new()
    self.sim_info_channel = channel.new()
    self.nas_channel = channel.new()
    self.gid_channel = channel.new()
    self.gps_info_channel = channel.new()
    self.refresh_rate_channel = channel.new()
    -- Other initial properties
    return self
end

return {
    new = new
}
