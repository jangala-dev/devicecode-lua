-- driver.lua
local fiber = require "fibers.fiber"
local op = require "fibers.op"
local queue = require "fibers.queue"
local context = require "fibers.context"
local sc = require "fibers.utils.syscall"
local sleep = require "fibers.sleep"
local at = require "services.hal.at"
local mmcli = require "services.hal.mmcli"
local utils = require "services.hal.utils"
local mode_overrides = require "services.hal.modem_driver.mode"
local model_overrides = require "services.hal.modem_driver.model"
local json = require "dkjson"
local cache = require "cache"
local log = require "log"
local wraperr = require "wraperr"

local CMD_TIMEOUT = 2

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

function Driver:get_info()
    local new_ctx = context.with_timeout(self.ctx, CMD_TIMEOUT)
    local cmd = mmcli.information(new_ctx, self.address)
    local out, err = cmd:combined_output()
    if err then return wraperr.new(err) end

    local info, _, err = json.decode(out)
    if err then return wraperr.new(err) end

    self.cache:set("modem", info.modem)
end

function Driver:get_at_ports()
    local ports = self:get("ports")
    ports = ports or {}

    local at_ports = {}

    for _, port in ipairs(ports) do
        -- ports are in string format "<port_name> (<port_type>)"
        local pname, ptype = port:match("^(.-) %((.-)%)$")
        if ptype == 'at' then
            table.insert(at_ports, pname)
        end
    end

    self.cache:set("modem", {generic = {at_ports = at_ports}})
end

function Driver:get(enquiry, stale)
    local command_list = {
        imei = {loc = {"modem", "generic", "equipment-identifier"}, func = self.get_info},
        device = {loc = {"modem", "generic", "device"}, func = self.get_info},
        drivers = {loc = {"modem", "generic", "drivers"}, func = self.get_info},
        plugin = {loc = {"modem", "generic", "plugin"}, func = self.get_info},
        model = {loc = {"modem", "generic", "model"}, func = self.get_info},
        revision = {loc = {"modem", "generic", "revision"}, func = self.get_info},
        state = {loc = {"modem", "generic", "state"}, func = self.get_info},
        state_failed_reason = {loc = {"modem", "generic", "state-failed-reason"}, func = self.get_info},
        primary_port = {loc = {"modem", "generic", "primary-port"}, func = self.get_info},
        ports = {loc = {"modem", "generic", "ports"}, func = self.get_info},
        at_ports = {loc = {"modem", "generic", "at_ports"}, func = self.get_at_ports}
    }

    local info = command_list[enquiry]
    if not info then return nil, wraperr.new("field no found in command list") end

    local value = self.cache:get(info.loc, stale)
    if not value then
        info.func(self)
        value = self.cache:get(info.loc)
        if not value then return nil, wraperr.new("value could not be retrieved from cache") end
    end

    return value, nil
end

function Driver:imei() return self:get("imei") end
function Driver:device() return self:get("device") end
function Driver:drivers() return self:get("drivers") end
function Driver:plugin() return self:get("plugin") end
function Driver:get_model() return self:get("model") end
function Driver:revision() return self:get("revision") end
function Driver:primary_port()
    local port, err = self:get("primary_port")
    if err then return nil, err end
    return "/dev/"..port, nil
end
function Driver:state() return self:get("state") end

function Driver:init()
    local err = self:get_info()
    if err then return err end

    -- let's get the driver mode
    local drivers, err = self:drivers()
    if not drivers then return err end

    for _, v in pairs(drivers) do
        self.mode = v=="qmi_wwan" and "qmi" or v=="cdc_mbim" and "mbim"
        if self.mode then break end
    end

    -- -- now let's enrich the driver with mode specific functions/overrides
    assert(mode_overrides.add_mode_funcs(self))

    -- let's now determine the manufacturer, model and variant
    local plugin, err = self:plugin()
    if not plugin then return err end

    local model, err = self:get_model()
    if not model then return err end

    local revision, err = self:revision()
    if not revision then return err end

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

    -- -- Finally we add any make/model specific functions/overrides
    model_overrides.add_model_funcs(self)
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

function Driver:connect()
    local cmd = mmcli.connect(self.address)
    return cmd:run()
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

-- Sim ID Methods

function Driver:spn()
end

function Driver:gid1(pin, puk)
end

function Driver:gid2(pin)
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

-- waits for presence of sim before activating the state monitor
function Driver:monitor_manager(bus_conn, index)
    while not self.ctx:err() do
        if self.autoconnect then
            self.wait_for_sim()
            if not self.ctx:err() and self:get("state") == 'failed' then
                local success = self:inhibit()
                while not success do
                    sleep.sleep(5)
                    success = self:inhibit()
                end
            end
        end
        self:state_monitor(bus_conn, index)
    end
end

function Driver:enable_autoconnect()
    self.autoconnect = true
end

local function is_state_transition(state_change, before, after)
    return state_change.prev_state == before and state_change.curr_state == after
end

function Driver:state_monitor(bus_conn, index)
    if self.ctx:err() then return end
    local imei = self:imei()
    local state_bus_path = 'hal/capability/modem/'..index..'/info/state'

    log.trace("Modem State Monitor: starting for imei - ", imei)

    local cmd = mmcli.monitor_state(self.address)
    local stdout = assert(cmd:stdout_pipe())
    local cmd_err = cmd:start()

    local exit_state = false

    if cmd_err then
        log.error("Modem State Monitor: failed to start for imei - ", imei)
    else
        while not (self.ctx:err() or exit_state) do
            for line in stdout:lines() do
                local state, err = utils.parse_modem_monitor(line)
                if err ~= nil then
                    log.error("Modem State Monitor: failed to parse line - ", line)
                else
                    bus_conn:publish({
                        topic = state_bus_path,
                        payload = state
                    })

                    -- some states signal a sim removal, therefore exit the monitor
                    if (is_state_transition(state, 'connected', 'registered')
                    or is_state_transition(state, 'registered', 'enabled')
                    or is_state_transition(state, 'failed', nil)
                    or state.type == 'removed') then
                        exit_state = true
                        break
                    end
                end
            end

            if not (self.ctx:err() or exit_state) then
                cmd:wait()
            end
        end
    end
    stdout:close()
    log.trace("Modem State Monitor: closing for imei - ", imei)
end

function Driver:command_manager()
    -- command table acts as a filter to prevent execution
    -- of all driver functions
    local command_table = {
        enable = self.enable,
        disable = self.disable,
        reset = self.reset,
        connect = self.connect,
        disconnect = self.disconnect,
        inhibit = self.inhibit
    }
    while not self.ctx:err() do
        local cmd_msg = op.choice(
            self.command_q:get_op(),
            self.ctx:done_op()
        ):perform()

        if cmd_msg == nil then return end

        -- only execute command if in command list
        local cmd = command_table[cmd_msg.command]
        local result = 'command does not exist'
        if cmd ~= nil then
            result = cmd(self, cmd_msg.args)
        end

        fiber.spawn(function ()
            op.choice(
                cmd_msg.return_channel:put_op(result),
                self.ctx:done_op()
            ):perform()
        end)
    end
end

local function new(ctx, address)
    local self = setmetatable({}, Driver)
    self.autoconnect = false
    self.ctx = ctx
    self.address = address
    self.cache = cache.new(0.1, sc.monotime)
    self.command_q = queue.new()
    -- Other initial properties
    return self
end

return {
    new = new
}
