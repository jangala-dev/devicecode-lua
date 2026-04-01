--- Modem backend getter methods
--- This module defines all the attribute accessor methods for ModemBackend

local fetch = require "services.hal.backends.fetch"

--- Adds all getter methods to the ModemBackend class
---@param ModemBackend table The ModemBackend class table
---@param fetch_modem_info function The fetch function for modem info
---@param fetch_sim_info function The fetch function for SIM info
---@param fetch_signal_info function The fetch function for signal info
---@param read_net_stat function The function to read network statistics
local function add_getters(ModemBackend, fetch_modem_info, fetch_sim_info, fetch_signal_info, read_net_stat)
    --- Gets the modem's IMEI number
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string imei
    ---@return string error
    function ModemBackend:imei(timeout)
        return fetch.get_cached_value(self.identity, "imei", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's device path
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string device
    ---@return string error
    function ModemBackend:device(timeout)
        return fetch.get_cached_value(self.identity, "device", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's primary port
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string primary_port
    ---@return string error
    function ModemBackend:primary_port(timeout)
        return fetch.get_cached_value(self.identity, "primary_port", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's AT ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table at_ports
    ---@return string error
    function ModemBackend:at_ports(timeout)
        return fetch.get_cached_value(self.identity, "at_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's QMI ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table qmi_ports
    ---@return string error
    function ModemBackend:qmi_ports(timeout)
        return fetch.get_cached_value(self.identity, "qmi_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's GPS ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table gps_ports
    ---@return string error
    function ModemBackend:gps_ports(timeout)
        return fetch.get_cached_value(self.identity, "gps_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's network ports
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table net_ports
    ---@return string error
    function ModemBackend:net_ports(timeout)
        return fetch.get_cached_value(self.identity, "net_ports", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's access technologies
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table access_techs
    ---@return string error
    function ModemBackend:access_techs(timeout)
        return fetch.get_cached_value(self.identity, "access_techs", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's SIM path
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string sim
    ---@return string error
    function ModemBackend:sim(timeout)
        return fetch.get_cached_value(self.identity, "sim", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's drivers
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table drivers
    ---@return string error
    function ModemBackend:drivers(timeout)
        return fetch.get_cached_value(self.identity, "drivers", self.cache, "table", timeout, fetch_modem_info)
    end

    --- Gets the modem's plugin
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string plugin
    ---@return string error
    function ModemBackend:plugin(timeout)
        return fetch.get_cached_value(self.identity, "plugin", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's model
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string model
    ---@return string error
    function ModemBackend:model(timeout)
        return fetch.get_cached_value(self.identity, "model", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's revision
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string revision
    ---@return string error
    function ModemBackend:revision(timeout)
        return fetch.get_cached_value(self.identity, "revision", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modem's operator name
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string operator
    ---@return string error
    function ModemBackend:operator(timeout)
        return fetch.get_cached_value(self.identity, "operator", self.cache, "string", timeout, fetch_modem_info)
    end

    --- Gets the modems rx bytes
    ---@return integer rx_bytes
    ---@return string error
    function ModemBackend:rx_bytes()
        return read_net_stat(self.identity.net_port, "rx_bytes")
    end

    --- Gets the modems tx bytes
    ---@return integer tx_bytes
    ---@return string error
    function ModemBackend:tx_bytes()
        return read_net_stat(self.identity.net_port, "tx_bytes")
    end

    --- Gets the modems signal
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return table signal_info
    ---@return string error
    function ModemBackend:signal(timeout)
        return fetch.get_cached_value(self.identity, "signal", self.cache, "table", timeout, fetch_signal_info)
    end

    --- Gets the modem's ICCID
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string iccid
    ---@return string error
    function ModemBackend:iccid(timeout)
        return fetch.get_cached_value(self.identity, "iccid", self.cache, "string", timeout, fetch_sim_info)
    end

    --- Gets the modem's IMSI
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string imsi
    ---@return string error
    function ModemBackend:imsi(timeout)
        return fetch.get_cached_value(self.identity, "imsi", self.cache, "string", timeout, fetch_sim_info)
    end

end

return {
    add_getters = add_getters
}
