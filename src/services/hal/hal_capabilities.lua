local channel = require "fibers.channel"

local function do_command(driver_q, cmd)
    cmd.return_channel = channel.new()
    driver_q:put(cmd)
    return cmd.return_channel:get()
end

local ModemCapability = {}
ModemCapability.__index = ModemCapability

local function new_modem_capability(driver_q)
    return setmetatable({driver_q = driver_q}, ModemCapability)
end

function ModemCapability:enable()
    local cmd = {command = "enable"}
    return do_command(self.driver_q, cmd)
end

function ModemCapability:disable()
    local cmd = {command = "disable"}
    return do_command(self.driver_q, cmd)
end

function ModemCapability:restart()
    local cmd = {command = "restart"}
    return do_command(self.driver_q, cmd)
end

function ModemCapability:connect(args)
    local cmd = {command = "connect", args = args}
    return do_command(self.driver_q, cmd)
end

function ModemCapability:disconnect()
    local cmd = {command = "disconnect"}
    return do_command(self.driver_q, cmd)
end

function ModemCapability:sim_detect()
    local cmd = { command = "sim_detect" }
    return do_command(self.driver_q, cmd)
end

function ModemCapability:fix_failure()
    local cmd = { command = "fix_failure" }
    return do_command(self.driver_q, cmd)
end

function ModemCapability:set_signal_update_freq(args)
    local cmd = { command = "set_signal_update_freq", args = args }
    return do_command(self.driver_q, cmd)
end

-- geo cap
local GeoCapability = {}
GeoCapability.__index = GeoCapability

local function new_geo_capability(driver_q)
    return setmetatable({driver_q = driver_q}, GeoCapability)
end

local TimeCapability = {}
TimeCapability.__index = TimeCapability

local function new_time_capability(driver_q)
    return setmetatable({ driver_q = driver_q }, TimeCapability)
end

-- uci cap
local UCICapability = {}
UCICapability.__index = UCICapability

local function new_uci_capability(driver_q)
    return setmetatable({driver_q = driver_q}, UCICapability)
end

function UCICapability:get(args)
    local cmd = {command = "get", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:set(args)
    local cmd = {command = "set", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:delete(args)
    local cmd = {command = "delete", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:commit(args)
    local cmd = {command = "commit", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:show(args)
    local cmd = {command = "show", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:add(args)
    local cmd = {command = "add", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:revert(args)
    local cmd = {command = "revert", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:changes(args)
    local cmd = {command = "changes", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:foreach(args)
    local cmd = {command = "foreach", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:set_restart_actions(args)
    local cmd = {command = "set_restart_actions", args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:ifup(args)
    local cmd = {command = 'ifup', args = args}
    return do_command(self.driver_q, cmd)
end

function UCICapability:halt_restarts()
    local cmd = {command = 'halt_restarts'}
    return do_command(self.driver_q, cmd)
end

function UCICapability:continue_restarts()
    local cmd = {command = 'continue_restarts'}
    return do_command(self.driver_q, cmd)
end

-- ubus cap
local UBusCapability = {}
UBusCapability.__index = UBusCapability

local function new_ubus_capability(driver_q)
    return setmetatable({driver_q = driver_q}, UBusCapability)
end

function UBusCapability:list()
    local cmd = {command = "list"}
    return do_command(self.driver_q, cmd)
end

function UBusCapability:call(args)
    local cmd = {command = "call", args = args}
    return do_command(self.driver_q, cmd)
end

function UBusCapability:listen(args)
    local cmd = {command = "listen", args = args}
    return do_command(self.driver_q, cmd)
end

function UBusCapability:stop_stream(args)
    local cmd = {command = "stop_stream", args = args}
    return do_command(self.driver_q, cmd)
end

function UBusCapability:send(args)
    local cmd = {command = "send", args = args}
    return do_command(self.driver_q, cmd)
end

-- wireless cap
local WirelessCapability = {}
WirelessCapability.__index = WirelessCapability

local function new_wireless_capability(driver_q)
    return setmetatable({driver_q = driver_q}, WirelessCapability)
end

function WirelessCapability:set_report_period(args)
    local cmd = {command = "set_report_period", args = args}
    return do_command(self.driver_q, cmd)
end

function WirelessCapability:set_channels(args)
    local cmd = {command = "set_channels", args = args}
    return do_command(self.driver_q, cmd)
end

function WirelessCapability:set_country(args)
    local cmd = {command = "set_country", args = args}
    return do_command(self.driver_q, cmd)
end

function WirelessCapability:set_txpower(args)
    local cmd = {command = "set_txpower", args = args}
    return do_command(self.driver_q, cmd)
end

function WirelessCapability:set_enabled(args)
    local cmd = {command = "set_enabled", args = args}
    return do_command(self.driver_q, cmd)
end

function WirelessCapability:add_interface(args)
    local cmd = {command = "add_interface", args = args}
    return do_command(self.driver_q, cmd)
end

function WirelessCapability:delete_interface(args)
    local cmd = {command = "delete_interface", args = args}
    return do_command(self.driver_q, cmd)
end

function WirelessCapability:apply()
    local cmd = {command = "apply"}
    return do_command(self.driver_q, cmd)
end

-- band cap
local BandCapability = {}
BandCapability.__index = BandCapability

local function new_band_capability(driver_q)
    return setmetatable({driver_q = driver_q}, BandCapability)
end

function BandCapability:set_kick_mode(args)
    local cmd = {command = "set_kick_mode", args = args}
    return do_command(self.driver_q, cmd)
end

function BandCapability:set_band_priority(args)
    local cmd = {command = "set_band_priority", args = args}
    return do_command(self.driver_q, cmd)
end

function BandCapability:set_client_kicking(args)
    local cmd = {command = "set_client_kicking", args = args}
    return do_command(self.driver_q, cmd)
end

function BandCapability:set_support_bonus(args)
    local cmd = {command = "set_support_bonus", args = args}
    return do_command(self.driver_q, cmd)
end

function BandCapability:set_update_freq(args)
    local cmd = {command = "set_update_freq", args = args}
    return do_command(self.driver_q, cmd)
end

function BandCapability:set_client_inactive_kickoff(args)
    local cmd = {command = "set_client_inactive_kickoff", args = args}
    return do_command(self.driver_q, cmd)
end

function BandCapability:set_client_cleanup(args)
    local cmd = {command = "set_client_cleanup", args = args}
    return do_command(self.driver_q, cmd)
end

function BandCapability:apply()
    local cmd = {command = "apply"}
    return do_command(self.driver_q, cmd)
end

return {
    new_modem_capability = new_modem_capability,
    new_ubus_capability = new_ubus_capability,
    new_geo_capability = new_geo_capability,
    new_time_capability = new_time_capability,
    new_uci_capability = new_uci_capability,
    new_wireless_capability = new_wireless_capability,
    new_band_capability = new_band_capability
}
