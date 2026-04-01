-- service modules
local modem_types = require "services.hal.types.modem"

-- Fiber modules
local fibers = require "fibers"
local exec = require "fibers.io.exec"
local op = require "fibers.op"

-- Other modules
local cache_mod = require "shared.cache"
local json = require "cjson.safe"
local getters = require "services.hal.backends.modem.providers.linux_mm.getters"


local function list_to_map(list)
    local map = {}
    for _, item in ipairs(list) do
        map[item] = true
    end
    return map
end

---- Constants ----
local CACHE_TIMEOUT = math.huge -- The default for cache is to hold a value indefinitely

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
}

local SIM_INFO_PATHS = {
    iccid = { "properties", "iccid" },
    imsi = { "properties", "imsi" },
}

local SIGNAL_TECHNOLOGIES = list_to_map {
    "5g",
    "cdma1x",
    "evdo",
    "gsm",
    "lte",
    "umts"
}

local SIGNAL_IGNORE_FIELDS = list_to_map {
    "error-rate"
}


---- Private functions ----

--- Format nested table into k-v pairs
---@param nested table
---@param key_paths table<string, string[]>
---@return table<string, any>
local function nested_to_flat(nested, key_paths)
    local flat = {}
    for key, path in pairs(key_paths) do
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

--- Shallow copy of a table
---@param tbl table
---@return table copy
local function shallow_copy(tbl)
    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = v
    end
    return copy
end

--- Formats each port from a string list of "name (type)" to a map of type_ports:name[]
--- Returns a table of cache keys to be stored separately
---@param ports string[]
---@return table<string, string[]> cache_entries Map of cache keys to values
local function format_ports(ports)
    local cache_entries = {}
    for _, port in ipairs(ports) do
        local name, type = port:match("^(.*) %((.*)%)$")
        if name and type then
            local key = type .. "_ports"
            if not cache_entries[key] then
                cache_entries[key] = {}
            end
            table.insert(cache_entries[key], name)
        end
    end
    return cache_entries
end

-- Post-processors transform field values before caching
-- Each processor must return a table of {key = value} pairs to cache
-- Example: ports -> {at_ports = [...], qmi_ports = [...]}
local FIELD_POST_PROCESSORS = {
    ports = format_ports, -- Expands to at_ports, qmi_ports, etc.
}


--- Fetches modem info using mmcli and caches it
---@param identity ModemIdentity
---@param cache Cache
---@return string error
local function fetch_modem_info(identity, cache)
    local st, _, err = fibers.run_scope(function()
        local cmd = exec.command {
            "mmcli", "-J", "-m", identity.address,
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            error("mmcli command failed: " .. tostring(err) .. ", output: " .. tostring(output))
        end

        local data, json_err = json.decode(output)
        if not data then
            error("Failed to decode mmcli output as JSON: " .. tostring(json_err) .. ", output: " .. tostring(output))
        end

        local modem = data.modem

        local flat = nested_to_flat(modem, MODEM_INFO_PATHS)

        -- Apply post-processors to transform fields before caching
        for field_name, processor in pairs(FIELD_POST_PROCESSORS) do
            if flat[field_name] then
                local cache_entries = processor(flat[field_name])
                for k, v in pairs(cache_entries) do
                    cache:set(k, v)
                end
                flat[field_name] = nil -- Remove original field since we cached the processed entries
            end
        end

        for k, v in pairs(flat) do
            cache:set(k, v)
        end
    end)
    return st ~= "ok" and err or ""
end

--- Read a net stat
---@param net_port string
---@return integer rx_bytes
---@return string error
local function read_net_stat(net_port, stat)
    local st, _, rx_bytes_or_err = fibers.run_scope(function()
        local path = '/sys/class/net/' .. net_port .. '/statistics/' .. stat
        local file = io.open(path, "r")
        if not file then
            error("Failed to open file: " .. tostring(path))
        end
        local content = file:read("*a")
        file:close()
        if not content then
            error("Failed to read file: " .. tostring(path))
        end
        local rx_bytes = tonumber(content)
        if not rx_bytes then
            error("Failed to parse rx_bytes: " .. tostring(content))
        end
        return rx_bytes
    end)

    if st == "ok" then
        return rx_bytes_or_err, ""
    end
    return -1, rx_bytes_or_err or "Unknown error"
end

--- Get the table values from the active signal tech
---@param signal_techs table
---@return table signals
---@return string error
local function get_active_signal(signal_techs)
    for tech, signals in pairs(signal_techs) do
        if SIGNAL_TECHNOLOGIES[tech] then
            local active_signal = false
            local filtered_fields = {}
            for signal_name, signal_value in pairs(signals) do
                if not SIGNAL_IGNORE_FIELDS[signal_name] and signal_value ~= "--" then
                    filtered_fields[signal_name] = signal_value
                    active_signal = true
                end
            end
            if active_signal then
                return filtered_fields, ""
            end
        end
    end
    return {}, "No active signal found"
end

--- Fetches signal info using mmcli and caches it
---@param identity ModemIdentity
---@param cache Cache
---@return string error
local function fetch_signal_info(identity, cache)
    local st, _, err = fibers.run_scope(function()
        local cmd = exec.command {
            "mmcli", "-J", "-m", identity.address, "--signal-get",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            error("mmcli command failed: --signal-get, reason: " .. tostring(err) .. ", output: " .. tostring(output))
        end

        local data, json_err = json.decode(output)
        if not data then
            error("Failed to decode mmcli output as JSON: " .. tostring(json_err) .. ", output: " .. tostring(output))
        end

        local signal_techs = data.modem and data.modem.signal or nil
        if not signal_techs then
            error("No signal info found in mmcli output: " .. tostring(output))
        end

        local active_signal, active_err = get_active_signal(signal_techs)
        if active_err ~= "" then
            error("Failed to get active signal: " .. tostring(active_err))
        end
        cache:set("signal", shallow_copy(active_signal)) -- Cache a copy of the active signal fields
    end)
    return st ~= "ok" and err or ""
end

--- Fetches SIM info using mmcli and caches it
---@param identity ModemIdentity
---@param cache Cache
---@return string error
local function fetch_sim_info(identity, cache)
    local st, _, err = fibers.run_scope(function()
        local sim = cache:get("sim")
        if not sim then
            fetch_modem_info(identity, cache) -- SIM info is needed to fetch SIM details, so fetch modem info if SIM path is not cached
            sim = cache:get("sim")
            if not sim then
                error("Failed to get SIM path for fetching SIM info")
            end
        end
        if sim == "--" then
            return -- no sim means we cannot get sim info
        end
        local cmd = exec.command {
            "mmcli", "-J", "-i", sim,
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            error("mmcli command failed: mmcli -J -i " ..
            sim .. ", reason:" .. tostring(err) .. ", output: " .. tostring(output))
        end
        local data, json_err = json.decode(output)
        if not data then
            error("Failed to decode mmcli output as JSON: " .. tostring(json_err) .. " , output: " .. tostring(output))
        end
        local flat = nested_to_flat(data.sim, SIM_INFO_PATHS)
        for k, v in pairs(flat) do
            cache:set(k, v)
        end
    end)
    return st ~= "ok" and err or ""
end


--- Returns all attributes needed for modem identity
---@param address string
---@param cache Cache
---@return ModemIdentity identity
local function get_identity(address, cache)
    -- Build a temp id
    local fake_id = assert(modem_types.new.ModemIdentity(
        "unknown",
        address,
        "unknown",
        "unknown",
        "unknown",
        "unknown"
    ))
    fetch_modem_info(fake_id, cache)                            -- We need modem info to build the identity

    local imei = cache:get("imei")
    local device = cache:get("device")

    local qmi_ports = cache:get("qmi_ports")
    local qmi_port
    if qmi_ports and type(qmi_ports) == "table" then
        qmi_port = qmi_ports[1]
    end

    local mbim_ports = cache:get("mbim_ports")
    local mbim_port
    if mbim_ports and type(mbim_ports) == "table" then
        mbim_port = mbim_ports[1]
    end

    local mode_port = "/dev/" .. (mbim_port or qmi_port) -- Prefer mbim port if available, otherwise use qmi port

    local at_ports = cache:get("at_ports")
    local at_port
    if at_ports and type(at_ports) == "table" then
        at_port = "/dev/" .. at_ports[1]
    end

    local net_ports = cache:get("net_ports")
    local net_port
    if net_ports and type(net_ports) == "table" then
        net_port = net_ports[1]
    end

    local id, id_err = modem_types.new.ModemIdentity(
        imei,
        address,
        mode_port,
        at_port,
        net_port,
        device
    )
    if not id then
        error("Failed to get modem identity: " .. tostring(id_err)) -- Fatal error if we cannot build the identity
    end

    return id
end

--- Parses the output of a modem state line
---@param line string?
---@return ModemStateEvent?
---@return string error
local function parse_modem_state_line(line)
    if not line or line == "" then
        return nil, "Command closed"
    end

    -- Remove leading/trailing whitespace
    line = line:match("^%s*(.-)%s*$")

    -- Pattern 1: Initial state, 'state'
    local initial_state = line:match(": Initial state, '([^']+)'")
    if initial_state then
        return modem_types.new.ModemStateInitialEvent(initial_state, "initial")
    end

    -- Pattern 2: State changed, 'old' --> 'new' (Reason: reason)
    local old_state, new_state, reason = line:match(": State changed, '([^']+)' %-%-> '([^']+)' %(Reason: ([^)]+)%)")
    if old_state and new_state then
        return modem_types.new.ModemStateChangeEvent(old_state, new_state, reason)
    end

    -- Pattern 3: Removed
    if line:match(": Removed") then
        return modem_types.new.ModemStateRemovedEvent("removed")
    end

    -- Unknown format
    return nil, "Unknown modem state line format: " .. line
end


---- Public backend interface ----
--- See ModemBackend class definition in services.hal.types.modem

local ModemBackend = {}
ModemBackend.__index = ModemBackend

-- Add all getter methods to ModemBackend
getters.add_getters(ModemBackend,
    fetch_modem_info,
    fetch_sim_info,
    fetch_signal_info,
    read_net_stat
)

--- Enable the modem
---@return boolean ok
---@return string error
function ModemBackend:enable()
    local st, _, err = fibers.run_scope(function()
        local cmd = exec.command {
            "mmcli", "-m", self.identity.address, "-e",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local _, status, _, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" then
            error("mmcli command failed to execute: enable, reason: " .. tostring(err))
        end
    end)
    return st == "ok", err or ""
end

--- Disable the modem
---@return boolean ok
---@return string error
function ModemBackend:disable()
    local st, _, err = fibers.run_scope(function()
        local cmd = exec.command {
            "mmcli", "-m", self.identity.address, "-d",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local _, status, _, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" then
            error("mmcli command failed to execute: disable, reason: " .. tostring(err))
        end
    end)
    return st == "ok", err or ""
end

--- Reset the modem
---@return boolean ok
---@return string error
function ModemBackend:reset()
    local st, _, err = fibers.run_scope(function()
        local cmd = exec.command {
            "mmcli", "-m", self.identity.address, "--reset",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local _, status, _, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" then
            error("mmcli command failed to execute: --reset, reason: " .. tostring(err))
        end
    end)
    return st == "ok", err or ""
end

--- Connect the modem
---@param conn_string string
---@return boolean ok
---@return string error
function ModemBackend:connect(conn_string)
    local full_conn_string = "--simple-connect=" .. conn_string
    local st, _, err = fibers.run_scope(function()
        local cmd = exec.command {
            "mmcli", "-m", self.identity.address, full_conn_string,
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local _, status, _, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" then
            error("mmcli command failed to execute: --simple-connect, reason: " .. tostring(err))
        end
    end)
    return st == "ok", err or ""
end

--- Disconnect the modem
---@return boolean ok
---@return string error
function ModemBackend:disconnect()
    local st, _, err = fibers.run_scope(function()
        local cmd = exec.command {
            "mmcli", "-m", self.identity.address, "--simple-disconnect",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local _, status, _, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" then
            error("mmcli command failed to execute: --simple-disconnect, reason: " .. tostring(err))
        end
    end)
    return st == "ok", err or ""
end

--- Inhibit the modem
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
        stderr = "stdout"
    }

    -- Accessing stdout_stream() triggers the command to start
    -- The command will run in the background, managed by the scope
    local stream, err = cmd:stdout_stream()
    if not stream then
        return false, "Failed to start inhibit command: --inhibit, reason: " .. tostring(err)
    end

    self.inhibit_cmd = cmd
    return true, "Modem inhibit started"
end

--- Uninhibit the modem
---@return boolean ok
---@return string error
function ModemBackend:uninhibit()
    if not self.inhibit_cmd then
        return false, "Modem is not inhibited"
    end

    self.inhibit_cmd:kill()
    self.inhibit_cmd = nil

    return true, "Modem uninhibited"
end

--- Start monitoring modem state changes
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
        stderr = "stdout"
    }
    local stream, err = cmd:stdout_stream()
    if not stream then
        return false, "Failed to start monitor state command: " .. tostring(err)
    end
    self.state_monitor = { cmd = cmd, stream = stream }
    return true, ""
end

--- Listen for modem state changes
---@return Op
function ModemBackend:monitor_state_op()
    return op.guard(function()
        if not self.state_monitor then
            return op.always(nil)
        end
        return self.state_monitor.stream:read_line_op():wrap(parse_modem_state_line)
    end)
end

--- Set the modem signal update interval
---@param period number
---@return boolean ok
---@return string error
function ModemBackend:set_signal_update_interval(period)
    local st, _, err = fibers.run_scope(function()
        local cmd = exec.command {
            "mmcli", "-m", self.identity.address, "--signal-setup=" .. tostring(period),
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local _, status, _, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" then
            error("mmcli command failed to execute: " .. tostring(err))
        end
    end)
    return st == "ok", err or ""
end

--- Builds the backend instance
--- @return ModemBackend
local function new(address)
    local cache = cache_mod.new(CACHE_TIMEOUT, nil, '.')
    local self = {
        cache = cache,
        identity = get_identity(address, cache),
        base = "linux_mm"
    }
    return setmetatable(self, ModemBackend)
end

return {
    new = new
}
