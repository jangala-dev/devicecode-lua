local expected = require 'services.ui.diagnostics_expected'
local helpers = require 'services.ui.diagnostics_helpers'
local request = require 'http.request'
local exec = require 'fibers.exec'
local log = require 'services.log'
local cjson = require "cjson.safe"

local tests = {}

local LOG_LEVELS = {
    NOTICE = "notice",
    WARN = "warn",
    ERROR = "error"
}

local dmesg_level_set = false

-- Configuring Dmesg log level to include Notice
local function ensure_dmesg_console_level()
    if dmesg_level_set then return end
    local _, err = exec.command("sh", "-c", "dmesg -n 5"):output()
    if err then
        log.error("UI - Error setting dmesg log level " .. tostring(err))
    else
        dmesg_level_set = true
    end
end

---Creates a new report table
---@param exp number Number of expected packages/services
---@param installed number Number of installed/running packages/services
---@param missing string[] Missing packages/services
---@return table<string, number|string[]> report
local function new_report(exp, installed, missing)
    return {
        expected = exp,
        installed = installed,
        missing = missing,
    }
end

---Check if the expected packages are installed
---@param expected_packages_installed string[]
---@param installed_packages string[]
---@return table<string, number|string[]> report
local function check_expected_packages_installed(expected_packages_installed, installed_packages)
    local total_installed = 0
    local missing = {}

    for _, package in ipairs(expected_packages_installed) do
        local installed = installed_packages[package] or false

        if not installed then
            table.insert(missing, package)
        else
            total_installed = total_installed + 1
        end
    end

    return new_report(#expected_packages_installed, total_installed, missing)
end

---Reports the runnning packages
---@param expected_packages_running string[]
---@return table<string, number|string[]>
local function check_expected_packages_running(expected_packages_running)
    local total_running = 0
    local missing = {}
    for _, package in ipairs(expected_packages_running) do
        if helpers.is_process_running(package) then
            total_running = total_running + 1
        else
            table.insert(missing, package)
        end
    end

    return new_report(#expected_packages_running, total_running, missing)
end

---Reports the running services
---@param box_type string getbox|bigbox
---@return table<string, number|string[]>|nil report
---@return string|nil error
local function check_expected_services_running(box_type)
    -- Get expected installed packages
    local expected_services_running, err = expected.get_expected_services_running(box_type)
    if err ~= nil then
        return nil, err
    end

    local total_running = 0
    local missing = {}
    for _, service in ipairs(expected_services_running) do
        if helpers.is_service_running(service) then
            total_running = total_running + 1
        else
            table.insert(missing, service)
        end
    end

    return new_report(#expected_services_running, total_running, missing)
end

---Fetches logs from dmesg with the specified log level
---@param log_level string
---@return string[]|nil logs
---@return string|nil error
local function get_dmesg_logs(log_level)
    ensure_dmesg_console_level()

    local output, err = exec.command("sh", "-c", 'dmesg | grep -E -i "' .. log_level .. '"'):output()
    if err then
        return nil, err
    end

    local logs = {}
    for line in output:gmatch("[^\r\n]+") do
        table.insert(logs, '[' .. string.upper(log_level) .. '][dmesg] ' .. line)
    end
    return logs, nil
end

---Fetches logs from logread with the specified log level
---@param log_level string
---@return string[]|nil logs
---@return string|nil error
local function get_logread_logs(log_level)
    local output, err = exec.command("sh", "-c", 'logread | grep -E -i "' .. log_level .. '"'):output()
    if err then
        return nil, err
    end

    local logs = {}
    for line in output:gmatch("[^\r\n]+") do
        table.insert(logs, '[' .. string.upper(log_level) .. '][logread] ' .. line)
    end
    return logs, nil
end

---Check if the correct number of modems are installed
---@param expected_modems number Number of expected modems
---@return table<string, number|string[]> report
---@return string|nil error
local function check_expected_modems_installed(expected_modems)
    local output, err = exec.command("mmcli", "-L"):output()
    if err then
        return {}, err
    end

    local installed_modems = 0
    for line in output:gmatch("[^\r\n]+") do
        if line:match("Modem") then
            installed_modems = installed_modems + 1
        end
    end

    return new_report(expected_modems, installed_modems, {}), nil
end

---Reports the installed bootstrap files
---@param expected_bootstrap_installed string[] Paths to expected bootstrap files
---@return table<string, number|string[]> report
---@return string|nil error
local function check_expected_bootstrap_installed(expected_bootstrap_installed)
    local bootstrap_installed_total = 0
    local missing = {}

    for _, path in ipairs(expected_bootstrap_installed) do
        local exists = helpers.file_exists(path)

        if exists then
            bootstrap_installed_total = bootstrap_installed_total + 1
        else
            table.insert(missing, path)
        end
    end

    return new_report(#expected_bootstrap_installed, bootstrap_installed_total, missing)
end

---Reports the installed packages
---@param box_type string getbox|bigbox
---@return table<string, number|string[]>|nil packages_installed
---@return string|nil error
local function get_packages_installed(box_type)
    -- Get expected installed packages
    local expected_packages_installed, exp_pkg_err = expected.get_expected_packages_installed(box_type)
    if exp_pkg_err ~= nil then
        return nil, exp_pkg_err
    end

    -- Get installed packages
    local installed_packages, inst_pkg_err = helpers.get_installed_packages()
    if inst_pkg_err ~= nil then
        return nil, inst_pkg_err
    end

    -- Check if packages are installed
    local packages_installed = check_expected_packages_installed(expected_packages_installed, installed_packages)
    return packages_installed, nil
end

---Reports the installed modems
---@param box_type string getbox|bigbox
---@return table<string, number|string[]>|nil modems_installed
---@return string|nil error
local function get_modems_installed(box_type)
    -- Get expected modems
    local expected_modems, exp_count_err = expected.get_expected_modem_count(box_type)
    if exp_count_err ~= nil then
        return nil, exp_count_err
    end

    -- Check if modems are installed
    local modems_installed, exp_inst_err = check_expected_modems_installed(expected_modems)
    if exp_inst_err ~= nil then
        return nil, exp_inst_err
    end

    return modems_installed, nil
end

---Simple ICMP reachability check for google (BusyBox ping)
---@param config table<string, string | table> The google configuration
---@return boolean
---@return string|nil error
function tests.test_google_connectivity(config)
    local out, err = exec.command("sh", "-c", "ping -c 1 -W 2 " .. config.ip):output()
    if err then return false, "ping error: " .. tostring(err) end
    -- BusyBox output usually includes "1 packets transmitted, 1 packets received" or "bytes from"
    if out:lower():match("1 packets received") or out:lower():match("bytes from") then
        return true, nil
    end
    return false, "no reply from " .. config.ip
end

---Test the connectivity to hawkbit
---@param config table<string, table | string> The hawkbit configuration
---@return boolean
---@return string|nil error
function tests.test_hawkbit_connectivity(config)
    if not config.url or not config.key then
        local err = "Hawkbit configuration is missing"
        log.error(err)
        return false, err
    end

    -- Make a request to hawkbit to check connectivity
    -- TODO shouldn't read from here
    local MAC_PATH = "/sys/class/net/eth0/address"
    local mac_address, err = helpers.get_parsed_mac(MAC_PATH)

    if err ~= nil then
        log.error('Error getting mac address: ' .. err)
        return false, err
    end

    local full_path = config.url .. "/default/controller/v1/" .. mac_address
    local req = request.new_from_uri(full_path)

    req.headers:upsert(":method", "GET")
    req.headers:upsert("authorization", "TargetToken " .. config.key)
    req.headers:upsert("content-type", "application/json")
    local headers, _ = req:go(10)

    if not headers then
        log.error("Request Timeout: No response from the Hawkbit server. Url: " .. full_path)
        return false, err
    elseif headers:get(":status") ~= "200" then
        log.error('Error connecting to hawkbit: ' .. headers:get(":status"))
        return false, err
    end

    return true, nil
end

---Test the connectivity to Unifi
---@param config table<string, table | string> The unifi configuration
---@return boolean
---@return string|nil error
function tests.test_unifi_connectivity(config)
    -- Check if the Unifi IP is set
    if not config.ip then
        local err = "Unifi IP is not set in the default config"
        log.error(err)
        return false, err
    end

    return true, nil
end

---Test the connectivity to Mainflux
---@param config table<string, table | string> The mainflux configuration
---@return boolean
---@return string|nil error
function tests.test_mainflux_connectivity(config)
    if not config.url or not config.key or not config.channels.data or not config.channels.control then
        local err = "Mainflux configuration is missing"
        log.error(err)
        return false, err
    end

    local full_path = config.url .. "/http/channels/" .. config.channels.data .. "/messages"
    -- Creating a SENML formatted message
    local req = request.new_from_uri(full_path)
    req.headers:upsert(":method", "POST")
    req.headers:upsert("authorization", "Thing " .. config.key)
    req.headers:upsert("content-type", "application/senml+json")
    req.headers:delete("expect")
    req:set_body(cjson.encode({ {
        vs = "Testing Mainflux Connectivity", ts = os.time(), n = "Diagnostics"
    }}))

    local res_headers, _ = req:go(10)

    if not res_headers then
        local err = "Request Timeout: No response from the Mainflux server. Url: " .. full_path
        log.error(err)
        return false, err
    elseif res_headers:get(":status") ~= "202" then
        local err = string.format("URL: %s | Response: %s", full_path, res_headers:get(":status"))
        log.error(err)
        return false, err
    end

    return true, nil
end

---@param box_type string getbox|bigbox
---@param config table<string, any> The configuration
---@return table<string, number|string[]>|nil report
---@return string|nil error
local function check_expected_cloud_services_reachable(box_type, config)
    local expected_tests, exp_tests_err = expected.get_expected_connectivity_tests(box_type)
    if exp_tests_err ~= nil then
        return nil, exp_tests_err
    end

    local expected = 0
    local installed = 0
    local missing = {}

    for name, test_fn_name in pairs(expected_tests) do
        expected = expected + 1
        local test_fn = tests[test_fn_name]
        if type(test_fn) ~= "function" then
            table.insert(missing, name .. " (missing test function)")
        else
            local ok, _ = test_fn(config[name])
            if ok then installed = installed + 1 else table.insert(missing, name) end
        end
    end

    return new_report(expected, installed, missing)
end

---Check which modems are active (SIM present and state machine running)
---@param box_type string Box model type
---@param stats_cache table|nil Flat stats messages cache
---@return table<string, number|string[]>|nil report
---@return string|nil error
local function get_modems_sim_active(box_type, stats_cache)
    local expected_modems, err = expected.get_expected_modem_names(box_type)
    if err ~= nil then
        return nil, err
    end

    local installed = 0
    local missing = {}

    if not stats_cache then
        return new_report(#expected_modems, 0, expected_modems), nil
    end

    for _, modem_name in ipairs(expected_modems) do
        local sim_key = "gsm.modem." .. modem_name .. ".sim"
        local sim_entry = stats_cache[sim_key]
        local sim_present = sim_entry and sim_entry.payload == "present"

        local state_key = "gsm.modem." .. modem_name .. ".state"
        local state_entry = stats_cache[state_key]
        local has_active_state = state_entry
            and state_entry.payload
            and state_entry.payload.curr_state
            and state_entry.payload.curr_state ~= ""

        local is_active = sim_present and has_active_state

        if is_active then
            installed = installed + 1
        else
            table.insert(missing, modem_name)
        end
    end

    return new_report(#expected_modems, installed, missing), nil
end

---Fetches diagnostics stats from the box
---@param config table<string, string> The configuration
---@param stats_cache table|nil Flat stats messages cache
---@return table<string, table> diagnostics
local function get_box_reports(config, stats_cache)
    local diagnostics = {
        packages_installed = {},
        modems_installed = {},
        modems_sim_active = {},
        services_running = {},
        packages_running = {},
        bootstrap_installed = {},
        cloud_services_reachable = {},
    }
    local hardware_info, hardware_info_err = helpers.get_hardware_info("/etc/hwrevision")

    if hardware_info_err == nil then
        -- Get packages installed currently
        local packages_installed, pkg_inst_err = get_packages_installed(hardware_info.model)
        if pkg_inst_err == nil then
            diagnostics.packages_installed = packages_installed
        else
            log.error("UI - error getting packages installed", pkg_inst_err)
        end

        -- Check modems
        local modems_installed, mod_inst_err = get_modems_installed(hardware_info.model)
        if mod_inst_err == nil then
            diagnostics.modems_installed = modems_installed
        else
            log.error("UI - error getting modems installed", mod_inst_err)
        end

        -- Check services running
        local services_running, exp_svc_err = check_expected_services_running(hardware_info.model)
        if exp_svc_err == nil then
            diagnostics.services_running = services_running
        else
            log.error("UI - error getting services running", exp_svc_err)
        end

        -- Check cloud services reachable
        local cloud_services, cloud_services_err = check_expected_cloud_services_reachable(hardware_info.model, config)
        if cloud_services_err ~= nil then
            log.error("UI - error checking cloud services reachable", cloud_services_err)
        else
            diagnostics.cloud_services_reachable = cloud_services
        end

        -- Check modem SIM active (present + state machine running)
        local modems_sim_active, sim_check_err = get_modems_sim_active(hardware_info.model, stats_cache)
        if sim_check_err ~= nil then
            log.error("UI - error checking modem SIM active", sim_check_err)
        else
            diagnostics.modems_sim_active = modems_sim_active
        end
    else
        log.error("UI - error getting hardware info", hardware_info_err)
    end

    -- Check if packages are running
    -- TODO will need to separate per device
    local packages_running = check_expected_packages_running(expected.packages_running)
    diagnostics.packages_running = packages_running

    -- Check bootstrapped
    local bootstrap_installed = check_expected_bootstrap_installed(expected.bootstrap_installed)
    diagnostics.bootstrap_installed = bootstrap_installed

    return diagnostics
end

---Fetches logs from dmesg and logread
---@return string[] logs
local function get_box_logs()
    local logs = {}

    local function log_appender(new_logs)
        for _, log in ipairs(new_logs) do
            table.insert(logs, log)
        end
    end
    for _, log_level in pairs(LOG_LEVELS) do
        local dmesg_logs, dmesg_read_err = get_dmesg_logs(log_level)
        if dmesg_read_err == nil then
            log_appender(dmesg_logs)
        end
        local logread_logs, logread_err = get_logread_logs(log_level)
        if logread_err == nil then
            log_appender(logread_logs)
        end
    end
    return logs
end

return {
    get_box_reports = get_box_reports,
    get_box_logs = get_box_logs,
}
