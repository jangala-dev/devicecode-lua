-- service modules
local modem_types = require "services.hal.types.modem"
local log = require "services.log"

-- Fiber modules
local fibers = require "fibers"
local exec = require "fibers.io.exec"
local op = require "fibers.op"
local fiber = require "fibers.fiber"
local scope = require "fibers.scope"

-- Other modules
local cache_mod = require "shared.cache"
local json = require "cjson.safe"
local getters = require "services.hal.backends.modem.providers.linux_mm.getters"


---- Constants ----
local CACHE_TIMEOUT = 10 -- seconds

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
}


---- Private functions ----

--- Format nested table into k-v pairs
---@param nested table
---@param key_paths table<string, string[]>
---@return table<string, any>
---@return string[] errors
local function nested_to_flat(nested, key_paths)
    local flat = {}
    local errors = {}
    for key, path in pairs(key_paths) do
        local value = nested
        for _, p in ipairs(path) do
            if type(value) ~= 'table' then
                table.insert(errors, "Expected table at path " .. table.concat(path, ".") .. ", got " .. type(value))
                break
            end
            value = value[p]
            if value == nil then
                table.insert(errors, "Missing value at path " .. table.concat(path, "."))
                break
            end
        end
        if value ~= nil then
            flat[key] = value
        end
    end
    return flat, errors
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
        else
            log.warn("Failed to parse port string: " .. tostring(port))
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
    local cmd = exec.command {
        "mmcli", "-J", "-m", identity.address,
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
    if status ~= "exited" or code ~= 0 then
        return "mmcli command failed: " .. tostring(err) .. ", output: " .. tostring(output)
    end

    local data, json_err = json.decode(output)
    if not data then
        return "Failed to decode mmcli output as JSON: " .. tostring(json_err) .. ", output: " .. tostring(output)
    end

    local modem = data.modem

    local flat, errors = nested_to_flat(modem, MODEM_INFO_PATHS)
    if #errors > 0 then
        log.warn("Errors formatting modem info: " .. table.concat(errors, ";\n\t"))
    end

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
    return ""
end

--- Returns all attributes needed for modem identity
---@param address string
---@param cache Cache
---@return ModemIdentity identity
local function get_identity(address, cache)
    -- Build a temp id
    local fake_id = assert(modem_types.new.ModemIdentity("unknown", address, "unknown", "unknown", "unknown"))
    local err = fetch_modem_info(fake_id, cache)                            -- We need modem info to build the identity
    if err ~= "" then
        error("Failed to fetch modem info for identity: " .. tostring(err)) -- Fatal error if we cannot get modem info
    end

    local imei = cache:get("imei")
    local primary_port = cache:get("primary_port")
    local device = cache:get("device")
    local at_ports = cache:get("at_ports")
    local at_port
    if at_ports and type(at_ports) == "table" then
        at_port = at_ports[1]
    end

    local id, id_err = modem_types.new.ModemIdentity(
        imei,
        address,
        primary_port,
        at_port,
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

---@class ModemBackend
---@field identity ModemIdentity
---@field cache Cache
---@field inhibit_cmd Command|nil
---@field imei fun(timeout: number?): string, string
---@field device fun(timeout: number?): string, string
---@field primary_port fun(timeout: number?): string, string
---@field at_ports fun(timeout: number?): table, string
---@field qmi_ports fun(timeout: number?): table, string
---@field gps_ports fun(timeout: number?): table, string
---@field net_ports fun(timeout: number?): table, string
---@field ignored_ports fun(timeout: number?): table, string
---@field access_techs fun(timeout: number?): table, string
---@field sim fun(timeout: number?): string, string
---@field drivers fun(timeout: number?): table, string
---@field plugin fun(timeout: number?): boolean, string
---@field model fun(timeout: number?): string, string
---@field revision fun(timeout: number?): string, string
local ModemBackend = {}
ModemBackend.__index = ModemBackend

-- Add all getter methods to ModemBackend
getters.add_getters(ModemBackend, fetch_modem_info)

--- Enable the modem
---@return string result
---@return number exit_code
function ModemBackend:enable()
    local cmd = exec.command {
        "mmcli", "-m", self.identity.address, "-e",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
    if status ~= "exited" then
        return "mmcli command failed to execute: " .. tostring(err), code
    end
    return output, code
end

--- Disable the modem
---@return string result
---@return number exit_code
function ModemBackend:disable()
    local cmd = exec.command {
        "mmcli", "-m", self.identity.address, "-d",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
    if status ~= "exited" then
        return "mmcli command failed to execute: " .. tostring(err), code
    end
    return output, code
end

--- Reset the modem
---@return string result
---@return number exit_code
function ModemBackend:reset()
    local cmd = exec.command {
        "mmcli", "-m", self.identity.address, "--reset",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
    if status ~= "exited" then
        return "mmcli command failed to execute: " .. tostring(err), code
    end
    return output, code
end

--- Connect the modem
---@param conn_string string
---@return string result
---@return number exit_code
function ModemBackend:connect(conn_string)
    local full_conn_string = "--simple-connect=" .. conn_string
    local cmd = exec.command {
        "mmcli", "-m", self.identity.address, full_conn_string,
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
    if status ~= "exited" then
        return "mmcli command failed to execute: " .. tostring(err), code
    end
    return output, code
end

--- Disconnect the modem
---@return string result
---@return number exit_code
function ModemBackend:disconnect()
    local cmd = exec.command {
        "mmcli", "-m", self.identity.address, "--simple-disconnect",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local output, status, code, _, err = fibers.perform(cmd:combined_output_op())
    if status ~= "exited" then
        return "mmcli command failed to execute: " .. tostring(err), code
    end
    return output, code
end

--- Inhibit the modem
---@return string result
---@return number exit_code
function ModemBackend:inhibit()
    if self.inhibit_cmd then
        return "Modem is already inhibited", 1
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
        return "Failed to start inhibit command: " .. tostring(err), 1
    end

    self.inhibit_cmd = cmd
    return "Modem inhibit started", 0
end

--- Uninhibit the modem
---@return string result
---@return number exit_code
function ModemBackend:uninhibit()
    if not self.inhibit_cmd then
        return "Modem is not inhibited", 0
    end

    self.inhibit_cmd:kill()
    self.inhibit_cmd = nil

    return "Modem uninhibited", 0
end

--- Listen for modem state changes
---@return Op
function ModemBackend:monitor_state_op()
    local cmd = exec.command {
        "mmcli", "-m", self.identity.address, "-w",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local stream, err = cmd:stdout_stream()
    if not stream then
        error("Failed to start monitor state command: " .. tostring(err))
    end
    return stream:read_line_op():wrap(parse_modem_state_line)
end



--- Builds the backend instance
--- @return ModemBackend
local function new(address)
    local cache = cache_mod.new(CACHE_TIMEOUT, nil, '.')
    local self = {
        cache = cache,
        identity = get_identity(address, cache),
    }
    return setmetatable(self, ModemBackend)
end

return {
    new = new
}
