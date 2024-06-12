-- driver.lua
local exec = require "fibers.exec"
local context = require "fibers.context"
local sc = require "fibers.utils.syscall"
local at = require "services.gsm.at"
local mode_overrides = require "services.gsm.modem_driver.mode"
local model_overrides = require "services.gsm.modem_driver.model"
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

local function starts_with(main_string, start_string)
    main_string, start_string = main_string:lower(), start_string:lower()
    -- Use string.sub to get the prefix of mainString that is equal in length to startString
    return string.sub(main_string, 1, string.len(start_string)) == start_string
end


function Driver:get_info()
    local new_ctx = context.with_timeout(self.ctx, CMD_TIMEOUT)
    local cmd = exec.command_context(new_ctx, 'mmcli', '-J', '-m', self.address)
    local out, err = cmd:combined_output()
    if err then return wraperr.new(err) end

    local info, _, err = json.decode(out)
    if err then return wraperr.new(err) end

    self.cache:set("modem", info.modem)
end

function Driver:get(enquiry)
    local command_list = {
        imei = {loc = {"modem", "generic", "equipment-identifier"}, func = self.get_info},
        device = {loc = {"modem", "generic", "device"}, func = self.get_info},
        drivers = {loc = {"modem", "generic", "drivers"}, func = self.get_info},
        plugin = {loc = {"modem", "generic", "plugin"}, func = self.get_info},
        model = {loc = {"modem", "generic", "model"}, func = self.get_info},
        revision = {loc = {"modem", "generic", "revision"}, func = self.get_info},
    }

    local info = command_list[enquiry]
    if not info then return nil, wraperr.new("placeholder error") end

    local value = self.cache:get(info.loc)
    if not value then
        info.func(self)
        value = self.cache:get(info.loc)
        if not value then return nil, wraperr.new("placeholder error") end
    end

    return value, nil
end

function Driver:imei() return self:get("imei") end
function Driver:device() return self:get("device") end
function Driver:drivers() return self:get("drivers") end
function Driver:plugin() return self:get("plugin") end
function Driver:model() return self:get("model") end
function Driver:revision() return self:get("revision") end

function Driver:init()
    self:get_info()

    -- let's get the driver mode
    local drivers, err = self:drivers()
    if not drivers then return err end

    for _, v in pairs(drivers) do
        self.mode = v=="qmi_wwan" and "qmi" or v=="cdc_mbim" and "mbim"
        if self.mode then break end
    end

    -- now let's enrich the driver with mode specific functions/overrides
    assert(mode_overrides.add_mode_funcs(self))

    -- let's now determine the manufacturer, model and variant
    local plugin, err = self:plugin()
    if not plugin then return err end

    local model, err = self:model()
    if not model then return err end

    local revision, err = self:revision()
    if not revision then return err end

    for man, mods in pairs(model_info) do
        if string.match(plugin:lower(), man) then
            self.manufacturer = man
            for _, details in ipairs(mods) do
                if details.mod_string == model:lower() or starts_with(revision, details.rev_string) then
                    log.info(man, details.model, details.model_variant, "detected at:", self.address)
                    self.model = details.model
                    self.model_variant = details.model_variant
                end
            end
            break
        end
    end

    -- Finally we add any make/model specific functions/overrides
    model_overrides.add_model_funcs(self)
end

-- Base methods can be defined here

function Driver:enable()
    print("Generic modem enable")
end

function Driver:disable()
end

function Driver:connect()
end

function Driver:disconnect()
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

local function new(ctx, address)
    local self = setmetatable({}, Driver)
    self.ctx = ctx
    self.address = address
    self.cache = cache.new(1, sc.monotime)
    -- Other initial properties
    return self
end

return {
    new = new
}
