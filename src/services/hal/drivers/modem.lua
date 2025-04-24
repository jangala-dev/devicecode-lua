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
local CMD_TIMEOUT = 2

---@class Driver
---@field ctx Context
---@field address string
---@field command_q Queue
---@field state_monitor_channel Channel
---@field modem_info_channel Channel
---@field sim_info_channel Channel
---@field nas_info_channel Channel
---@field gid_info_channel Channel
---@field gps_info_channel Channel
---@field refresh_rate_channel Channel
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

---returns a list of control and info capabilities for the modem
---@return table
function Driver:get_capabilities()
    local capabilities = {}
    capabilities.modem = {
        control = hal_capabilities.new_modem_capability(self.command_q),
        info_streams = {
            { name = 'state', channel = self.state_monitor_channel, endpoints = 'single' },
            { name = 'modem', channel = self.modem_info_channel,    endpoints = 'multiple' },
            { name = 'sim',   channel = self.sim_info_channel,      endpoints = 'multiple' },
            { name = 'nas',   channel = self.nas_info_channel,      endpoints = 'multiple' },
            { name = 'gids',  channel = self.gid_info_channel,      endpoints = 'multiple' }
        }
    }
    return capabilities
end
---continuously polls the modem for modem and sim information
function Driver:poll_info()
    local poll_freq = 10
    while not self.ctx:err() do
        local infos = {}
        local modem_info, modem_err = self:get_modem_info()
        if modem_err then
            log.error(string.format("Modem - %s: Failed to get modem info: %s", self.imei, modem_err))
        else
            infos.modem = modem_info
        end

        if infos.modem and infos.modem.generic.sim ~= '--' then
            local sim_info, sim_err = self:get_sim_info(infos.modem.generic.sim)
            if sim_err then
                log.debug("Sim - %s: Failed to get sim info: %s", self.imei, sim_err)
            else
                infos.sim = sim_info
            end
        end

        if infos.modem and infos.modem["3gpp"]["registration-state"] ~= '--' then
            local nas_info, nas_err = self.get_nas_info()
            if nas_err then
                log.debug("MCC MNC failed retrieval", nas_err)
            else
                infos.nas = nas_info
            end
        end

        if infos.modem and infos.modem.generic.state ~= 'failed' then
            local gids, gid_err = self.uim_get_gids()
            if gid_err then
                log.debug(gid_err)
            else
                infos.gid = gids
            end
        end

        for k, v in pairs(infos) do
            local info_channel = self[k .. "_info_channel"]
            if v and info_channel then
                op.choice(
                    info_channel:put_op(v),
                    self.ctx:done_op()
                ):perform()
            end
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
---Reads mmcli modem output into a table structure
---@return table?
---@return table? error
function Driver:get_modem_info()
    local new_ctx = context.with_timeout(self.ctx, CMD_TIMEOUT)
    local cmd = mmcli.information(new_ctx, self.address)
    local out, err = cmd:combined_output()
    if err then return nil, wraperr.new(err) end

    local info, _, err = json.decode(out)
    if err then return nil, wraperr.new(err) end

    return info.modem, nil
end

---Reads mmcli sim output into a table structure
---@param sim_address string
---@return table?
---@return table? error
function Driver:get_sim_info(sim_address)
    local new_ctx = context.with_timeout(self.ctx, CMD_TIMEOUT)
    local cmd = mmcli.sim_information(new_ctx, sim_address)
    local out, err = cmd:combined_output()
    if err then return nil, wraperr.new(err) end

    local info, _, err = json.decode(out)
    if err then return nil, wraperr.new(err) end

    return info.sim, nil
end
---Gets initial modem information and binds protocol specific functions to the driver
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

---Starts modem information, monitor and command manager fibers
---@param bus_conn Connection
function Driver:spawn(bus_conn)
    service.spawn_fiber('Modem Info Poll - ' .. self.imei, bus_conn, self.ctx, function()
        self:poll_info()
    end)
    service.spawn_fiber('Modem State Monitor - ' .. self.imei, bus_conn, self.ctx, function()
        self:state_monitor()
    end)
    service.spawn_fiber('Modem Command Manager - ' .. self.imei, bus_conn, self.ctx, function()
        self:command_manager()
    end)
end

-- Base methods can be defined here

function Driver:set_func_min()
    local cmd_ctx = context.with_timeout(self.ctx, 0.3)
    return at.send_with_context(cmd_ctx, "AT+CFUN=0")
end

function Driver:set_func_max()
    local cmd_ctx = context.with_timeout(self.ctx, 0.3)
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

function Driver:sim_detect()
    fiber.spawn(function()
        self.wait_for_sim()
    end)
    return true, nil
end

function Driver:fix_failure()
    fiber.spawn(function()
        self.wait_for_sim()
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
-- Sim ID Methods

function Driver:spn()
end


-- Pin Methods

function Driver:send_pin(pin)

end

function Driver:send_puk(pin, puk)
end

function Driver:enable_pin(pin)
end

function Driver:disable_pin(pin)
end

function Driver:change_pin(cur_pin, new_pin)
end

local function is_state_transition(state_change, before, after)
    return state_change.prev_state == before and state_change.curr_state == after
end

-- Listens for modem state changes and sends them to HAL
function Driver:state_monitor()
    if self.ctx:err() then return end

    log.trace("Modem State Monitor: starting for imei - ", self.imei)

    local cmd = mmcli.monitor_state(self.address)
    local stdout = assert(cmd:stdout_pipe())
    local cmd_err = cmd:start()

    if cmd_err then
        log.error("Modem State Monitor: failed to start for imei - ", self.imei)
    else
        while not self.ctx:err() do
            while not self.ctx:err() do
                local line, ctx_err = op.choice(
                    stdout:read_line_op(),
                    self.ctx:done_op():wrap(function()
                        return nil, self.ctx:err()
                    end)
                ):perform()
                if ctx_err or line == nil then
                    cmd:kill()
                    break
                end
                local state, err = utils.parse_modem_monitor(line)
                if err ~= nil then
                    log.error(err)
                else
                    -- When a sim is removed mmcli hops to enabled state moving through all intermediate states
                    -- connected -> registered -> enabled
                    local need_sim_check = is_state_transition(state, 'connected', 'registered')
                        or is_state_transition(state, 'registered', 'enabled')

                    -- adding an extra state on top of the mmcli modem states, lets
                    -- gsm know a sim is not present instead of just being in the 'enabled' state
                    if need_sim_check then
                        local inserted, inserted_check_err = self.is_sim_inserted()
                        if inserted_check_err then
                            log.error(inserted_check_err)
                        else
                            if not inserted then
                                state.curr_state = 'no_sim'
                            end
                        end
                    end

                    self.state_monitor_channel:put(state)
                end
            end

            if not self.ctx:err() then
                cmd:wait()
            end
        end
    end
    stdout:close()
    log.trace("Modem State Monitor: closing for imei - ", self.imei)
end

---Listens for commands from HAL and executes them
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
    --create info channels
    self.state_monitor_channel = channel.new()
    self.modem_info_channel = channel.new()
    self.sim_info_channel = channel.new()
    self.nas_info_channel = channel.new()
    self.gid_info_channel = channel.new()
    self.gps_info_channel = channel.new()

    self.refresh_rate_channel = channel.new()
    -- Other initial properties
    return self
end

return {
    new = new
}
