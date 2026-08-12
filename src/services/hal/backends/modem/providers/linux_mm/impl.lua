-- service modules
local modem_types = require "services.hal.types.modem"

-- Fiber modules
local fibers = require "fibers"
local exec = require "fibers.io.exec"
local op = require "fibers.op"
local scope = require "fibers.scope"

-- Other modules
local json = require "cjson.safe"
local process_flags = require "services.hal.backends.modem.process_flags"

local function terminate_command(cmd, sig)
    if not cmd or type(cmd.kill) ~= 'function' then return true, nil end
    local ok, a, b = pcall(function() return cmd:kill(sig or 15) end)
    if not ok then return nil, tostring(a) end
    if a == false or a == nil then return nil, tostring(b or 'command kill failed') end
    return true, nil
end

local MODEM_INFO_PATHS = {
    imei = { "generic", "equipment-identifier" },
    device = { "generic", "device" },
    primary_port = { "generic", "primary-port" },
    ports = { "generic", "ports" },
    access_techs = { "generic", "access-technologies" },
    sim = { "generic", "sim" },
    drivers = { "generic", "drivers" },
    plugin = { "generic", "plugin" },
    model = { "generic", "model" },
    revision = { "generic", "revision" },
    operator = { "3gpp", "operator-name" },
    modem_state = { "generic", "state" },
    sim_lock = { "generic", "unlock-required" },
    sim_lock_retries = { "generic", "unlock-retries" },
}

local SIM_INFO_PATHS = {
    iccid = { "properties", "iccid" },
    imsi = { "properties", "imsi" },
}

local VALID_SIGNAL_RANGES = {
    ["5g"] = {
        rssi = { low = -125, high = -30 }, -- dBm
        rsrp = { low = -156, high = -31 }, -- dBm
        rsrq = { low = -43, high = 20 },   -- dB
        snr  = { low = -23, high = 40 },   -- dB
    },

    cdma1x = {
        rssi = { low = -125, high = -30 }, -- dBm
        ecio = { low = -31.5, high = 0 },  -- dB
    },

    evdo = {
        rssi = { low = -125, high = -30 }, -- dBm
        ecio = { low = -31.5, high = 0 },  -- dB
        sinr = { low = -9, high = 9 },     -- dB
        io   = { low = -125, high = -30 }, -- dBm
    },

    gsm = {
        rssi = { low = -125, high = -30 }, -- dBm
    },

    lte = {
        rssi = { low = -125, high = -30 }, -- dBm
        rsrp = { low = -140, high = -44 }, -- dBm
        rsrq = { low = -20, high = -3 },   -- dB
        snr  = { low = -20, high = 30 },   -- dB
    },

    umts = {
        rssi = { low = -125, high = -30 }, -- dBm
        rscp = { low = -120, high = -25 }, -- dBm
        ecio = { low = -24, high = 0 },    -- dB
    },
}

---@param signal number
---@param range { low: number, high: number }
---@return boolean
local function is_signal_valid(signal, range)
    return type(signal) == 'number'
        and signal == signal
        and signal ~= math.huge
        and signal ~= -math.huge
        and type(range) == 'table'
        and type(range.low) == 'number'
        and type(range.high) == 'number'
        and signal >= range.low
        and signal <= range.high
end

---@param nested table
---@param key_paths table<string, string[]>
---@return table<string, any>
local function nested_to_flat(nested, key_paths)
    local flat = {}
    for key, path in pairs(key_paths) do
        ---@type any
        local value = nested
        for _, p in ipairs(path) do
            if type(value) ~= 'table' then
                value = nil
                break
            end
            value = value[p]
            if value == nil then
                break
            end
        end
        if value ~= nil then
            flat[key] = value
        end
    end
    return flat
end

---@param ports string[]
---@return table<string, string[]>
local function format_ports(ports)
    local formatted = {
        at_ports = {},
        qmi_ports = {},
        gps_ports = {},
        net_ports = {},
        mbim_ports = {},
    }
    for _, port in ipairs(ports) do
        local name, port_type = port:match("^(.*) %((.*)%)$")
        if name and port_type then
            local key = port_type .. "_ports"
            if formatted[key] then
                table.insert(formatted[key], name)
            end
        end
    end
    return formatted
end

---@param value any
---@return string[]
local function normalize_string_list(value)
    if type(value) == 'table' then
        local result = {}
        for _, entry in ipairs(value) do
            if type(entry) == 'string' and entry ~= '' then
                table.insert(result, entry)
            end
        end
        return result
    end
    if type(value) == 'string' and value ~= '' and value ~= "--" then
        return { value }
    end
    return {}
end

---@param value any
---@return string?
local function normalize_optional_string(value)
    if type(value) ~= 'string' then return nil end
    if value == '' or value == '--' then return nil end
    return value
end

---@param value any
---@return table<string, integer>?
local function normalize_unlock_retries(value)
    if type(value) ~= 'table' then return nil end
    local out = {}
    for _, entry in ipairs(value) do
        if type(entry) == 'string' then
            local key, retries = entry:match("^%s*([^%(]-)%s*%((%d+)%)%s*$")
            if key and retries then
                key = key:match("^%s*(.-)%s*$")
                if key ~= '' then
                    out[key] = tonumber(retries)
                end
            end
        end
    end
    if next(out) == nil then return nil end
    return out
end

---@param output string
---@return string
local function parse_firmware_version(output)
    for line in output:gmatch("[^\r\n]+") do
        local version = line:match("version:%s*(%S+)")
        if version and version ~= '' then
            return version
        end
    end
    return ""
end

---@param drivers string[]
---@param ports table<string, string[]>
---@return string?
local function derive_mode(drivers, ports)
    local drivers_str = table.concat(drivers or {}, ",")
    if drivers_str:match("cdc_mbim") or #(ports.mbim_ports or {}) > 0 then
        return "mbim"
    end
    if drivers_str:match("qmi_wwan") or #(ports.qmi_ports or {}) > 0 then
        return "qmi"
    end
    return nil
end

---@param address string
---@param args string[]
---@return string? output
---@return string error
local function run_command(address, args)
    local st, _, output_or_err = fibers.run_scope(function()
        local cmd_args = {
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        for _, arg in ipairs(args) do
            table.insert(cmd_args, arg)
        end
        local cmd = exec.command(cmd_args)
        local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            error(table.concat(args, " ") .. " failed for modem " .. tostring(address) .. ": " .. tostring(err)
                .. ", output: " .. tostring(output))
        end
        return output
    end)

    if st == "ok" then
        return output_or_err, ""
    end
    return nil, output_or_err or "unknown command error"
end

---@param address string
---@return table<string, any>?
---@return string error
local function parse_modem_info_json(output)
    local data, json_err = json.decode(output)
    if not data then
        return nil, "Failed to decode mmcli info output as JSON: "
            .. tostring(json_err) .. ", output: " .. tostring(output)
    end
    if type(data.modem) ~= 'table' then
        return nil, "No modem info found in mmcli output"
    end

    local flat = nested_to_flat(data.modem, MODEM_INFO_PATHS)
    local ports = format_ports(flat.ports or {})
    flat.ports = nil
    for key, value in pairs(ports) do
        flat[key] = value
    end
    flat.drivers = normalize_string_list(flat.drivers)
    flat.access_techs = normalize_string_list(flat.access_techs)
    flat.modem_state = normalize_optional_string(flat.modem_state)
    flat.sim_lock = normalize_optional_string(flat.sim_lock)
    flat.sim_lock_retries = normalize_unlock_retries(flat.sim_lock_retries)
    return flat, ""
end

---@param address string
---@return table<string, any>?
---@return string error
local function read_modem_info(address)
    local output, err = run_command(address, { "mmcli", "-J", "-m", address })
    if not output then
        return nil, err
    end

    return parse_modem_info_json(output)
end

---@param identity ModemIdentity
---@return string?
---@return string error
local function read_firmware_version(identity)
    local output, err = run_command(identity.address, { "mmcli", "-m", identity.address, "--firmware-status" })
    if not output then
        return nil, err
    end

    local version = parse_firmware_version(output)
    if version == "" then
        return nil, "Failed to parse firmware version from mmcli --firmware-status"
    end
    return version, ""
end

---@param output string
---@return ModemSignalInfo?
---@return string error
local function parse_signal_info_json(output)
    local data, json_err = json.decode(output)
    if not data then
        return nil, "Failed to decode mmcli output as JSON: " .. tostring(json_err) .. ", output: " .. tostring(output)
    end

    local signal_techs = data.modem and data.modem.signal or nil
    if type(signal_techs) ~= 'table' then
        return nil, "No signal info found in mmcli output"
    end

    local valid_signals = {}
    for tech, signals in pairs(signal_techs) do
        local expected_signals = VALID_SIGNAL_RANGES[tech]
        if expected_signals and type(signals) == 'table' then
            local filtered_fields = {}
            for signal_name, range in pairs(expected_signals) do
                local numeric_value = tonumber(signals[signal_name])
                if is_signal_valid(numeric_value, range) then
                    filtered_fields[signal_name] = numeric_value
                end
            end
            if next(filtered_fields) ~= nil then
                valid_signals[tech] = filtered_fields
            end
        end
    end

    -- An empty table is a successful observation that no valid signal is
    -- currently available. The driver emits it so consumers can clear stale
    -- retained signal state instead of treating it as a failed modem read.
    return modem_types.new.ModemSignalInfo(valid_signals)
end

---@param identity ModemIdentity
---@return ModemSignalInfo?
---@return string error
local function read_signal_info(identity)
    local output, err = run_command(identity.address, { "mmcli", "-J", "-m", identity.address, "--signal-get" })
    if not output then
        return nil, err
    end

    return parse_signal_info_json(output)
end

---@param sim_path string
---@return table<string, any>?
---@return string error
local function read_sim_payload(sim_path)
    local output, err = run_command(sim_path, { "mmcli", "-J", "-i", sim_path })
    if not output then
        return nil, err
    end

    local data, json_err = json.decode(output)
    if not data then
        return nil,
            "Failed to decode mmcli SIM output as JSON: " .. tostring(json_err) .. ", output: " .. tostring(output)
    end
    if type(data.sim) ~= 'table' then
        return nil, "No SIM info found in mmcli output"
    end

    return nested_to_flat(data.sim, SIM_INFO_PATHS), ""
end

---@param net_port string
---@param stat string
---@return integer
---@return string
local function read_net_stat(net_port, stat)
    local st, _, value_or_err = fibers.run_scope(function()
        local path = "/sys/class/net/" .. net_port .. "/statistics/" .. stat
        local file = io.open(path, "r")
        if not file then
            error("Failed to open file: " .. tostring(path))
        end
        local content = file:read("*a")
        file:close()
        if not content then
            error("Failed to read file: " .. tostring(path))
        end
        local value = tonumber(content)
        if not value then
            error("Failed to parse net stat: " .. tostring(content))
        end
        return value
    end)

    if st == "ok" then
        return value_or_err, ""
    end
    return -1, value_or_err or "Unknown error"
end

---@param address string
---@return ModemIdentity
local function get_identity(address)
    local modem_info, err = read_modem_info(address)
    if not modem_info then
        error("Failed to fetch modem info: " .. tostring(err))
    end

    local qmi_port = modem_info.qmi_ports and modem_info.qmi_ports[1] or nil
    local mbim_port = modem_info.mbim_ports and modem_info.mbim_ports[1] or nil
    local selected_mode_port = mbim_port or qmi_port
    if not selected_mode_port then
        error("Failed to determine modem control port")
    end

    local at_port = modem_info.at_ports and modem_info.at_ports[1] or nil
    if not at_port then
        error("Failed to determine modem AT port")
    end

    local net_port = modem_info.net_ports and modem_info.net_ports[1] or nil
    if not net_port then
        error("Failed to determine modem network port")
    end

    local identity, id_err = modem_types.new.ModemIdentity(
        modem_info.imei,
        address,
        "/dev/" .. selected_mode_port,
        "/dev/" .. at_port,
        net_port,
        modem_info.device
    )
    if not identity then
        error("Failed to get modem identity: " .. tostring(id_err))
    end
    return identity
end

---@param line string?
---@return ModemStateEvent?
---@return string error
local function parse_modem_state_line(line)
    if not line or line == "" then
        return nil, "Command closed"
    end

    line = line:match("^%s*(.-)%s*$")

    local initial_state = line:match(": Initial state, '([^']+)'")
    if initial_state then
        return modem_types.new.ModemStateInitialEvent(initial_state, "initial")
    end

    local old_state, new_state, reason = line:match(": State changed, '([^']+)' %-%-> '([^']+)' %(Reason: ([^)]+)%)")
    if old_state and new_state then
        return modem_types.new.ModemStateChangeEvent(old_state, new_state, reason)
    end

    if line:match(": Removed") then
        return modem_types.new.ModemStateRemovedEvent("removed")
    end

    return nil, "Unknown modem state line format: " .. line
end

local ModemBackend = {}
ModemBackend.__index = ModemBackend

-- Default firmware fetch; model hooks may override this via self-dispatch
ModemBackend._read_firmware = read_firmware_version

---@return ModemIdentityInfo?
---@return string error
function ModemBackend:read_identity()
    local modem_info, err = read_modem_info(self.identity.address)
    if not modem_info then
        return nil, err
    end

    local firmware = self._read_firmware(self.identity)
    -- Non-fatal: firmware may not be available yet, or the model hook may not be installed yet.
    -- The driver will re-call read_identity() after model hooks are applied.
    firmware = firmware or nil

    return modem_types.new.ModemIdentityInfo(
        modem_info.imei,
        modem_info.drivers or {},
        modem_info.model,
        modem_info.revision,
        firmware,
        modem_info.plugin,
        derive_mode(modem_info.drivers or {}, {
            qmi_ports = modem_info.qmi_ports or {},
            mbim_ports = modem_info.mbim_ports or {},
        })
    )
end

---@return ModemPortsInfo?
---@return string error
function ModemBackend:read_ports()
    local modem_info, err = read_modem_info(self.identity.address)
    if not modem_info then
        return nil, err
    end

    return modem_types.new.ModemPortsInfo(
        modem_info.device,
        modem_info.primary_port,
        modem_info.at_ports,
        modem_info.qmi_ports,
        modem_info.gps_ports,
        modem_info.net_ports
    )
end

---@return ModemSimInfo?
---@return string error
function ModemBackend:read_sim_info()
    local modem_info, err = read_modem_info(self.identity.address)
    if not modem_info then
        return nil, err
    end

    local sim_info = nil
    if modem_info.sim and modem_info.sim ~= "--" then
        sim_info, err = read_sim_payload(modem_info.sim)
        if err ~= "" then
            return nil, err
        end
    end

    return modem_types.new.ModemSimInfo(
        modem_info.sim,
        sim_info and sim_info.iccid or nil,
        sim_info and sim_info.imsi or nil,
        nil,
        modem_info.sim_lock,
        modem_info.sim_lock_retries,
        modem_info.modem_state
    )
end

---@return ModemNetworkInfo?
---@return string error
function ModemBackend:read_network_info()
    local modem_info, err = read_modem_info(self.identity.address)
    if not modem_info then
        return nil, err
    end

    return modem_types.new.ModemNetworkInfo(
        modem_info.operator,
        modem_info.access_techs,
        nil,
        nil,
        nil
    )
end

---@return ModemSignalInfo?
---@return string error
function ModemBackend:read_signal()
    return read_signal_info(self.identity)
end

---@return ModemTrafficInfo?
---@return string error
function ModemBackend:read_traffic()
    local rx_bytes, rx_err = read_net_stat(self.identity.net_port, "rx_bytes")
    if rx_err ~= "" then
        return nil, rx_err
    end

    local tx_bytes, tx_err = read_net_stat(self.identity.net_port, "tx_bytes")
    if tx_err ~= "" then
        return nil, tx_err
    end

    return modem_types.new.ModemTrafficInfo(rx_bytes, tx_bytes)
end

---@return boolean ok
---@return string error
function ModemBackend:enable()
    local _, err = run_command(self.identity.address, { "mmcli", "-m", self.identity.address, "-e" })
    return err == "", err
end

---@return boolean ok
---@return string error
function ModemBackend:disable()
    local _, err = run_command(self.identity.address, { "mmcli", "-m", self.identity.address, "-d" })
    return err == "", err
end

---@return boolean ok
---@return string error
function ModemBackend:reset()
    local _, err = run_command(self.identity.address, { "mmcli", "-m", self.identity.address, "--reset" })
    return err == "", err
end

---@param conn_string string
---@return boolean ok
---@return string error
function ModemBackend:connect(conn_string)
    local _, err = run_command(self.identity.address, {
        "mmcli", "-m", self.identity.address, "--simple-connect=" .. conn_string
    })
    return err == "", err
end

---@return boolean ok
---@return string error
function ModemBackend:disconnect()
    local _, err = run_command(self.identity.address, { "mmcli", "-m", self.identity.address, "--simple-disconnect" })
    return err == "", err
end

---@return boolean ok
---@return string error
function ModemBackend:inhibit()
    if self.inhibit_cmd then
        return false, "Modem is already inhibited"
    end

    local cmd = exec.command {
        "mmcli", "-m", self.identity.address, "--inhibit",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout",
        flags = process_flags.owned_monitor_flags(),
    }

    local stream, err = cmd:stdout_stream()
    if not stream then
        return false, "Failed to start inhibit command: --inhibit, reason: " .. tostring(err)
    end

    self.inhibit_cmd = cmd
    return true, "Modem inhibit started"
end

---@param timeout number?
---@return Op
function ModemBackend:uninhibit_op(timeout)
    return op.guard(function()
        local cmd = self.inhibit_cmd
        if not cmd then
            return op.always(false, "Modem is not inhibited")
        end

        self.inhibit_cmd = nil
        return cmd:shutdown_op(timeout or 1.0):wrap(function(status, _code, _sig, err)
            if status == "exited" or status == "signalled" then
                return true, "Modem uninhibited"
            end
            return false, err or ("failed to stop inhibit command: " .. tostring(status))
        end)
    end)
end

---@param timeout number?
---@return boolean ok
---@return string error
function ModemBackend:uninhibit(timeout)
    return fibers.perform(self:uninhibit_op(timeout))
end

---@return boolean ok
---@return string error
function ModemBackend:start_state_monitor()
    if self.state_monitor then
        return false, "Already monitoring modem state"
    end
    local cmd = exec.command {
        "mmcli", "-m", self.identity.address, "-w",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout",
        flags = process_flags.owned_monitor_flags(),
    }
    local stream, err = cmd:stdout_stream()
    if not stream then
        return false, "Failed to start monitor state command: " .. tostring(err)
    end
    self.state_monitor = { cmd = cmd, stream = stream }
    return true, ""
end

---@param timeout number?
---@return Op
function ModemBackend:stop_state_monitor_op(timeout)
    return op.guard(function()
        local rec = self.state_monitor
        self.state_monitor = nil

        if not rec then
            return op.always(true, "")
        end

        if rec.stream then
            pcall(function() rec.stream:terminate("modem_state_monitor_stop") end)
        end

        if not rec.cmd then
            return op.always(true, "")
        end

        return rec.cmd:shutdown_op(timeout or 1.0):wrap(function(status, _code, _sig, err)
            if status == "exited" or status == "signalled" then
                return true, ""
            end
            return false, err or ("state monitor shutdown failed: " .. tostring(status))
        end)
    end)
end

---@param timeout number?
---@return boolean ok
---@return string error
function ModemBackend:stop_state_monitor(timeout)
    return fibers.perform(self:stop_state_monitor_op(timeout))
end

local function terminate_monitor_record(rec, stream_key, reason)
    if not rec then
        return
    end

    local stream = rec[stream_key]
    if stream then
        pcall(function() stream:terminate(reason) end)
    end

    if rec.cmd then
        terminate_command(rec.cmd, 15)
    end
end

---Best-effort non-blocking teardown for scope finalisers.
---@param reason string?
function ModemBackend:terminate(reason)
    reason = reason or "modem_backend_terminated"

    terminate_monitor_record(self.sim_present, "stdout", reason)
    self.sim_present = nil

    terminate_monitor_record(self.state_monitor, "stream", reason)
    self.state_monitor = nil

    if self.inhibit_cmd then
        terminate_command(self.inhibit_cmd, 15)
        self.inhibit_cmd = nil
    end
end

---@param timeout number?
---@return Op
function ModemBackend:shutdown_op(timeout)
    timeout = timeout or 1.0

    return scope.run_op(function(s)
        local errors = {}

        if self.stop_sim_presence_monitor_op then
            local ok, err = s:perform(self:stop_sim_presence_monitor_op(timeout))
            if not ok then errors[#errors + 1] = tostring(err) end
        end

        if self.stop_state_monitor_op then
            local ok, err = s:perform(self:stop_state_monitor_op(timeout))
            if not ok then errors[#errors + 1] = tostring(err) end
        end

        if self.inhibit_cmd and self.uninhibit_op then
            local ok, err = s:perform(self:uninhibit_op(timeout))
            if not ok then errors[#errors + 1] = tostring(err) end
        end

        if #errors > 0 then
            return false, table.concat(errors, "; ")
        end

        return true, ""
    end):wrap(function(st, _, ...)
        if st == "ok" then
            return ...
        elseif st == "cancelled" then
            return false, "cancelled"
        end
        return false, (... or "modem backend shutdown failed")
    end)
end

---@param timeout number?
---@return boolean ok
---@return string error
function ModemBackend:shutdown(timeout)
    return fibers.perform(self:shutdown_op(timeout))
end

---@return Op
function ModemBackend:monitor_state_op()
    return op.guard(function()
        if not self.state_monitor then
            return op.always(nil)
        end
        return self.state_monitor.stream:read_line_op():wrap(function(line)
            local state_ev, err = parse_modem_state_line(line)
            if state_ev then
                self.last_state_event = state_ev
            end
            return state_ev, err
        end)
    end)
end

---@param period number
---@return boolean ok
---@return string error
function ModemBackend:set_signal_update_interval(period)
    local _, err = run_command(self.identity.address, {
        "mmcli", "-m", self.identity.address, "--signal-setup=" .. tostring(period)
    })
    return err == "", err
end

---@return ModemBackend
local function new(address)
    local self = {
        identity = get_identity(address),
        base = "linux_mm",
        last_state_event = nil,
    }
    return setmetatable(self, ModemBackend)
end

return {
    new = new,
    _test = {
        is_signal_valid = is_signal_valid,
        normalize_unlock_retries = normalize_unlock_retries,
        parse_modem_info_json = parse_modem_info_json,
        parse_signal_info_json = parse_signal_info_json,
        valid_signal_ranges = VALID_SIGNAL_RANGES,
    },
}
