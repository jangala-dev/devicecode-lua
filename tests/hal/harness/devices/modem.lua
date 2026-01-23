local templates = require 'tests.hal.templates'
local fiber = require 'fibers.fiber'
local modem_registry = require 'tests.hal.harness.devices.modem_registry'

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

local MODEM_STATE = {
    -- Upwards movement
    FAILED = 0,
    DISABLED = 1,
    ENABLING = 2,
    ENABLED = 3,
    SEARCHING = 4,
    REGISTERED = 5,
    CONNECTING = 6,
    CONNECTED = 7,
    -- Downwards movement
    DISCONNECTING = 8,
    DISABLING = 9,
}

local Sim = {}
Sim.__index = Sim

function Sim.new()
    local self = {}
    self.active = true
    return setmetatable(self, Sim)
end

function Sim:set_imsi(imsi)
    self.imsi = imsi
end

function Sim:set_operator(operator_id, operator_name)
    self.operator_id = operator_id
    self.operator_name = operator_name
end

function Sim:get_infomation()
    local overrides = {
        sim = {
            ["active"] = self.active,
            ["imsi"] = self.imsi,
            ["operator-id"] = self.operator_id,
            ["operator-name"] = self.operator_name,
        },
    }
    return templates.make_sim_information(overrides)
end

local Modem = {}
Modem.__index = Modem

-- helper functions

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

-- Internal helpers ---------------------------------------------------------

local function make_sim_dbus_path(index)
    return string.format("/org/freedesktop/ModemManager1/SIM/%s", tostring(index))
end

local function clone_table(t)
    local res = {}
    for k, v in pairs(t or {}) do
        if type(v) == 'table' then
            res[k] = clone_table(v)
        else
            res[k] = v
        end
    end
    return res
end

-- Rebuild the mmcli -J -m information JSON based on current modem state.
function Modem:_refresh_mmcli_information()
    local state = self.state
    if type(state) ~= "string" then
        state = tostring(state or "disabled")
    end

    local sim_path = self.sim_path
    if sim_path ~= nil and type(sim_path) ~= "string" then
        sim_path = tostring(sim_path)
    end

    local registration_state = self.registration_state
    if type(registration_state) ~= "string" then
        registration_state = tostring(registration_state or "--")
    end

    local generic_overrides = {
        state = state,
        sim = sim_path or "--",
    }

    local threegpp_overrides = {
        ["registration-state"] = registration_state,
    }

    local overrides = {
        modem = {
            generic = generic_overrides,
            ["3gpp"] = threegpp_overrides,
        }
    }

    local encoded = templates.make_modem_information(overrides)
    self.mmcli_data.information = encoded

    -- Update the existing static information command, if the backend has
    -- already created one for this address.
    local info_cmds = require('tests.hal.harness.backends.mmcli').information_cmds
    local info_cmd = info_cmds[self.mmcli_data.address]
    if info_cmd and info_cmd.write_out then
        info_cmd:write_out(encoded)
    end
end

-- local function modem_state_machine(modem)
--     -- Placeholder: the real state machine will be event-driven based on
--     -- mmcli/qmicli shim commands. For now, we just initialise the
--     -- high-level state once; tests explicitly calling configuration
--     -- methods are responsible for refreshing information when state
--     -- changes.
--     modem.state = 'disabled'
--     modem.registration_state = "--"
--     -- Call as a plain function because the modem table has not yet
--     -- been given its metatable when this is invoked from Modem.new.
--     Modem._refresh_mmcli_information(modem)
-- end

-- Modem hardware simulation methods

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

function Modem:insert_sim(sim)
    self.sim = sim
    -- For now we always use SIM index 0 for the single
    -- simulated SIM slot.
    self.sim_path = make_sim_dbus_path(0)
    -- When a SIM is inserted on real hardware, the modem does
    -- not immediately transition into a registered state.
    -- Instead, the SIM presence changes, the driver detects
    -- this via QMI slot monitoring, and then power-cycles /
    -- resets the modem which eventually comes back in a
    -- disabled state. Reflect that by only updating SIM
    -- presence here and leaving state transitions to the
    -- driver-driven reset / power-cycle paths.
    self:_refresh_mmcli_information()
end

function Modem:remove_sim()
    self.sim = nil
    self.sim_path = nil
    -- Clear SIM-related information but keep the current modem
    -- state; any subsequent power-cycle/reset logic will drive
    -- the state machine as in real hardware.
    self.registration_state = "--"
    self:_refresh_mmcli_information()
    if self.qmi_slot_monitor_cmd then
        self:_emit_sim_slot_status('absent')
    end
end

function Modem:block_signal()
    -- TODO: make it so the modem cannot get past searching state
end

function Modem:unblock_signal()
    -- TODO: make it so the modem can get past searching state into registered state
end

function Modem:block_connection()
    -- TODO: make it so the modem cannot connect to network
end

function Modem:unblock_connection()
    -- TODO: make it so the modem can connect to network
end

-- Modem configuration methods

function Modem:set_address_index(index)
    self.mmcli_data.address = make_full_address(index)
    modem_registry.set_address(self, self.mmcli_data.address)
end

function Modem:set_mmcli_information(overrides)
    -- Allow tests to set a custom base template; store both the raw
    -- information and decoded fields we care about.
    local information = templates.make_modem_information(overrides)
    self.mmcli_data.information = information
end

-- Optional: allow tests to explicitly bind a QMI port to this modem so
-- that qmicli backend commands can be routed back here.
function Modem:set_qmi_port(port)
    self.qmi_port = port
    modem_registry.set_qmi_port(self, port)
end

-- Command handlers invoked from the mmcli/qmicli backends -------------

function Modem:on_mmcli_monitor_state_start(cmd)
    -- Remember the state monitor command so that subsequent state
    -- changes can emit updates.
    self.state_monitor_cmd = cmd
    local initial_state = self.state or 'disabled'
    local line = string.format("Initial state: '%s'\n", initial_state)
    cmd:stdout_pipe() -- ensure stdout exists
    local err = cmd:write_out(line)
    return err
end

local function emit_state_change(modem, prev, curr)
    if not modem.state_monitor_cmd then return end
    if prev == curr then return end
    local line = string.format("State changed: '%s' -> '%s'\n", prev, curr)
    modem.state_monitor_cmd:write_out(line)
end

function Modem:_set_state(new_state)
    local prev = self.state or new_state
    if prev == new_state then
        return
    end
    self.state = new_state
    fiber.spawn(function()
        emit_state_change(self, prev, new_state)
        self:_refresh_mmcli_information()
    end)
end

local function inhibited_error(cmd)
    local err = "modem inhibited"
    cmd:stderr_pipe()
    cmd:write_err(err .. "\n")
    return err
end

local function failed_state_error(cmd)
    local err = "WrongState: modem in failed state"
    cmd:stderr_pipe()
    cmd:write_err(err .. "\n")
    return err
end

function Modem:on_mmcli_enable(cmd)
    if self.inhibited then
        return inhibited_error(cmd)
    end
    if self.state == 'failed' then
        return failed_state_error(cmd)
    end

    if self.state == 'disabled' then
        self.registration_state = 'home'
        self:_set_state('registered')
    end

    return nil
end

function Modem:on_mmcli_disable(cmd)
    if self.inhibited then
        return inhibited_error(cmd)
    end
    if self.state == 'failed' then
        return failed_state_error(cmd)
    end

    self.registration_state = "--"
    self:_set_state('disabled')
    return nil
end

function Modem:on_mmcli_connect(cmd, connection_string)
    if self.inhibited then
        return inhibited_error(cmd)
    end
    if self.state ~= 'registered' then
        local err = string.format("cannot connect from state '%s'", tostring(self.state))
        cmd:stderr_pipe()
        cmd:write_err(err .. "\n")
        return err
    end

    self:_set_state('connected')
    cmd:stdout_pipe()
    cmd:write_out("connected\n")
    return nil
end

function Modem:on_mmcli_disconnect(cmd)
    if self.inhibited then
        return inhibited_error(cmd)
    end
    if self.state ~= 'connected' then
        local err = string.format("cannot disconnect from state '%s'", tostring(self.state))
        cmd:stderr_pipe()
        cmd:write_err(err .. "\n")
        return err
    end

    self:_set_state('registered')
    cmd:stdout_pipe()
    cmd:write_out("disconnected\n")
    return nil
end

local function perform_reset(modem)
    modem.registration_state = "--"
    -- Model a drop-off and re-appearance of the modem on the
    -- monitor_modems channel while keeping the same address.
    fiber.spawn(function()
        modem:disappear()
        modem:_set_state('disabled')
        modem:appear()
    end)
end

function Modem:on_mmcli_reset(cmd)
    if self.inhibited then
        return inhibited_error(cmd)
    end
    perform_reset(self)
    return nil
end

function Modem:on_mmcli_inhibit_start(cmd)
    self.inhibited = true
    return nil
end

function Modem:on_mmcli_inhibit_end(cmd)
    self.inhibited = false
end

function Modem:on_mmcli_signal_setup(cmd, rate)
    -- For now, just accept the requested rate; the driver will also
    -- update its own refresh_rate_channel.
    cmd:stdout_pipe()
    cmd:write_out(string.format("signal setup %s\n", tostring(rate)))
    return nil
end

function Modem:on_qmi_uim_sim_power_off(cmd, port)
    self.sim_powered = false
    local powered_off_msg = string.format(
        "[%s] Successfully performed SIM power off", tostring(port)
    )
    fiber.spawn(function()
        cmd:write_out(powered_off_msg)
        cmd:write_out(nil)
    end)
    return nil
end

function Modem:on_qmi_uim_sim_power_on(cmd, port)
    self.sim_powered = true

    local powered_on_msg = string.format(
        "[%s] Successfully performed SIM power on", tostring(port)
    )
    fiber.spawn(function()
        cmd:write_out(powered_on_msg)
        cmd:write_out(nil)
    end)
    -- If a SIM is present when power is turned back on, model the
    -- behaviour as a modem reset.
    if self.sim then
        -- Emit a QMI slot-status indication so any wait_for_sim
        -- logic can observe the SIM becoming present.
        fiber.spawn(function()
            perform_reset(self)
        end)
        if self.qmi_slot_monitor_cmd then
            fiber.spawn(function()
                self:_emit_sim_slot_status('present')
            end)
        end
    end
    return nil
end

-- Emit a minimal QMI slot status indication matching the format
-- expected by utils.parse_slot_monitor, using the simulated port
-- name from our QMI mapping.
function Modem:_emit_sim_slot_status(card_status)
    if not self.qmi_slot_monitor_cmd or not self.qmi_port then return end
    -- Keep this to a single logical line so that the
    -- "Card status ... Slot status ..." pattern matches even
    -- though Lua patterns do not make '.' span newlines.
    local body = string.format(
        "Card status: %s Slot status: active",
        card_status
    )
    -- self.qmi_slot_monitor_cmd:stdout_pipe()
    self.qmi_slot_monitor_cmd:write_out(body)
end

function Modem:on_qmi_uim_monitor_start(cmd, port)
    self.qmi_slot_monitor_cmd = cmd
    -- Real qmicli does not replay the last slot-status event on
    -- monitor start; it only emits on subsequent changes. The
    -- dummy will therefore emit status lines only when the SIM
    -- state actually changes (insert/remove/power events).
    return nil
end

function Modem.new(ctx, initial_state)
    local self = {}
    self.ctx = ctx
    self.mmcli_data = {}
    self.mmcli_data.information = templates.make_modem_information()
    self.mmcli_cmds = {
        monitor_modems = mmcli.monitor_modems()
    }
    self.state = initial_state or 'disabled'
    self.registration_state = "--"
    self.sim = nil
    self.sim_path = nil
    self.sim_powered = true
    self.inhibited = false
    self.signal_blocked = false
    self.connection_blocked = false
    self.qmi_slot_monitor_cmd = nil
    setup_mmcli_commands(self.mmcli_cmds)
    self.qmicli_data = {}
    -- For now we hard-code the primary QMI port to match the
    -- default modem information template used by tests.
    self.qmi_port = "/dev/cdc-wdm0"
    modem_registry.set_qmi_port(self, self.qmi_port)
    local modem = setmetatable(self, Modem)
    modem:_refresh_mmcli_information()
    return modem
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
    no_modem = NoModem.new,
    new_sim = Sim.new
}
