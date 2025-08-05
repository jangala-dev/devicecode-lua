local expected = require 'services.ui.diagnostics_expected'
local helpers = require 'services.ui.diagnostics_helpers'
local exec = require 'fibers.exec'

local LOG_LEVELS = {
    NOTICE = "notice",
    WARN = "warn",
    ERROR = "error"
}

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

---Fetches diagnostics stats from the box
---@return table<string, table> diagnostics
local function get_box_reports()
    local diagnostics = {
        packages_installed = {},
        modems_installed = {},
        services_running = {},
        packages_running = {},
        bootstrap_installed = {},
    }
    local hardware_info, hardware_info_err = helpers.get_hardware_info("/etc/hwrevision")

    if hardware_info_err == nil then
        -- Get packages installed currently
        local packages_installed, pkg_inst_err = get_packages_installed(hardware_info.model)
        if pkg_inst_err == nil then
            diagnostics.packages_installed = packages_installed
        end

        -- Check modems
        local modems_installed, mod_inst_err = get_modems_installed(hardware_info.model)
        if mod_inst_err == nil then
            diagnostics.modems_installed = modems_installed
        end

        -- Check services running
        local services_running, exp_svc_err = check_expected_services_running(hardware_info.model)
        if exp_svc_err == nil then
            diagnostics.services_running = services_running
        end
    end

    -- Check if packages are running
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

-- Configuring Dmesg log level to include Notice
local _, err = exec.command("sh", "-c", "dmesg -n 5"):output()
if err then
    exec.command("logger", "-p", "err", "-t", "device_code", "Error setting dmesg log level: " .. tostring(err)):run()
end

return {
    get_box_reports = get_box_reports,
    get_box_logs = get_box_logs,
}
