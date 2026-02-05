--- Modem backend getter methods
--- This module defines all the attribute accessor methods for ModemBackend

--- Default try to get value from cache, if not present fetch modem info and try again
---@param identity ModemIdentity
---@param key string
---@param cache Cache
---@param ret_type string
---@param timeout number?
---@return any value
---@return string error
local function get_cached_value(identity, key, cache, ret_type, timeout, fetch_fn)
    local cached = cache:get(key, timeout)
    if cached then
        return cached, ""
    end

    local err = fetch_fn(identity, cache)
    if err ~= "" then
        return nil, "Failed to fetch modem info: " .. tostring(err)
    end

    local value = cache:get(key, timeout)
    if not value then
        return nil, "Value not found in cache after refresh: " .. tostring(key)
    end

    if type(value) == ret_type then
        return value, ""
    else
        return nil, "Cached value has wrong type: expected " .. ret_type .. ", got " .. type(value)
    end
end

--- Adds all getter methods to the ModemBackend class
---@param ModemBackend table The ModemBackend class table
---@param fetch_modem_info function The fetch function for modem info
local function add_getters(ModemBackend, fetch_modem_info)
    --- Gets the modem's IMEI number
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string imei
    ---@return string error
    function ModemBackend:imei(timeout)
        return get_cached_value(self.identity, "imei", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's device path
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string device
    ---@return string error
    function ModemBackend:device(timeout)
        return get_cached_value(self.identity, "device", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's primary port
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string primary_port
    ---@return string error
    function ModemBackend:primary_port(timeout)
        return get_cached_value(self.identity, "primary_port", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's AT ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table at_ports
    ---@return string error
    function ModemBackend:at_ports(timeout)
        return get_cached_value(self.identity, "at_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's QMI ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table qmi_ports
    ---@return string error
    function ModemBackend:qmi_ports(timeout)
        return get_cached_value(self.identity, "qmi_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's GPS ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table gps_ports
    ---@return string error
    function ModemBackend:gps_ports(timeout)
        return get_cached_value(self.identity, "gps_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's network ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table net_ports
    ---@return string error
    function ModemBackend:net_ports(timeout)
        return get_cached_value(self.identity, "net_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's ignored ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table ignored_ports
    ---@return string error
    function ModemBackend:ignored_ports(timeout)
        return get_cached_value(self.identity, "ignored_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's access technologies
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table access_techs
    ---@return string error
    function ModemBackend:access_techs(timeout)
        return get_cached_value(self.identity, "access_techs", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's SIM path
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string sim
    ---@return string error
    function ModemBackend:sim(timeout)
        return get_cached_value(self.identity, "sim", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's drivers
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table drivers
    ---@return string error
    function ModemBackend:drivers(timeout)
        return get_cached_value(self.identity, "drivers", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's plugin
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return boolean plugin
    ---@return string error
    function ModemBackend:plugin(timeout)
        return get_cached_value(self.identity, "plugin", self.cache, "boolean", timeout, fetch_modem_info)
    end

    --- Gets the modem's model
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string model
    ---@return string error
    function ModemBackend:model(timeout)
        return get_cached_value(self.identity, "model", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's revision
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string revision
    ---@return string error
    function ModemBackend:revision(timeout)
        return get_cached_value(self.identity, "revision", self.cache, "string", timeout, fetch_modem_info)
    end
end

return {
    add_getters = add_getters
}
