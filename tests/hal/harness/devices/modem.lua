local templates = require 'tests.hal.templates'

-- Mock out external modem commands
local real_mmcli = require 'services.hal.drivers.modem.mmcli'
local mmcli = require 'tests.hal.harness.backends.mmcli'
local mock_err = real_mmcli.use_backend(mmcli)
if mock_err then
    error("Failed to set mmcli backend: " .. mock_err)
end

local real_qmicli = require 'services.hal.drivers.modem.qmicli'
local qmicli = require 'tests.hal.harness.backends.qmicli'
local mock_err = real_qmicli.use_backend(qmicli)
if mock_err then
    error("Failed to set qmicli backend: " .. mock_err)
end

local Modem = {}
Modem.__index = Modem

local function make_full_address(index)
    return string.format("/org/freedesktop/ModemManager1/Modem/%s", tostring(index))
end

local function make_monitor_event(is_added, address)
    local sign = is_added and '(+)' or '(-)'
    return string.format("%s %s [DUMMY MANAFACUTER] Dummy Modem Module", sign,
        address)
end

local function setup_mmcli_commands(commands)
    commands.monitor_modems:stdout_pipe() -- create stdout pipe to share with modem manager
end

function Modem:appear()
    if not self.mmcli_data.address then
        return "No address set for modem"
    end

    local wr_err = self.mmcli_cmds.monitor_modems:write_out(make_monitor_event(true, self.mmcli_data.address))
    if wr_err then return wr_err end

    -- create info command output before modem is added
    local information_cmd = mmcli.information(self.ctx, self.mmcli_data.address)
    wr_err = information_cmd:write_out(self.mmcli_data.information)
    return wr_err or nil
end

function Modem:disappear()
    if not self.mmcli_data.address then
        return "No address set for modem"
    end

    local wr_err = self.mmcli_cmds.monitor_modems:write_out(make_monitor_event(false, self.mmcli_data.address))
    if wr_err then return wr_err end
end

function Modem:set_address_index(index)
    self.mmcli_data.address = make_full_address(index)
end

function Modem:set_mmcli_information(overrides)
    self.mmcli_data.information = templates.make_modem_information(overrides)
end

function Modem.new(ctx)
    local self = {}
    self.ctx = ctx
    self.mmcli_data = {}
    self.mmcli_data.information = templates.make_modem_information()
    self.mmcli_cmds = {
        monitor_modems = mmcli.monitor_modems()
    }
    setup_mmcli_commands(self.mmcli_cmds)
    self.qmicli_data = {}
    return setmetatable(self, Modem)
end

local NoModem = {}
NoModem.__index = NoModem

function NoModem.new()
    local self = {}
    self.mmcli_cmds = {
        monitor_modems = mmcli.monitor_modems()
    }
    setup_mmcli_commands(self.mmcli_cmds)
    return setmetatable(self, NoModem)
end

function NoModem:appear()
    local wr_err = self.mmcli_cmds.monitor_modems:write_out("No modems were found")
    if wr_err then return wr_err end
end

return {
    new = Modem.new,
    no_modem = NoModem.new
}
