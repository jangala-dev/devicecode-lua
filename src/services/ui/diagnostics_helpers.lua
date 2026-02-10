local exec = require 'fibers.exec'

---Check if a process is running
---@param process string
---@return boolean is_running
local function is_process_running(process)
    local output, err = exec.command("sh", "-c", "pgrep -af " .. process .. " | grep -v pgrep"):output()
    if err then
        return false
    end
    return #output > 0
end

---Check if a service is running
---@param service string
---@return boolean is_running
local function is_service_running(service)
    local output, err = exec.command("/etc/init.d/" .. service, "status"):output()
    if err or #output == 0 then
        return false
    end
    return output:match("running") ~= nil
end

---Check if a file exists
---@param path string
---@return boolean
local function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

---Get the packages installed on the device
---@return string[] installed_packages
---@return string|nil error
local function get_installed_packages()
    local output, err = exec.command("opkg", "list-installed"):output()
    if err then
        return output, err
    end

    local installed_packages = {}
    for line in output:gmatch("[^\r\n]+") do
        local package = line:match("^(%S+)")
        if package then
            installed_packages[package] = true
        end
    end
    return installed_packages, nil
end

---Read a file and return its content
---@param path string
---@param slurp boolean
---@return string|nil content
---@return string|nil error
local function read_file(path, slurp)
    local file, error, content
    if path == nil then
        return nil, "Path is nil"
    end
    if slurp then
        file, error = io.open(path)
    else
        file, error = io.open(path, "rb")
    end
    if file then
        content = file:read("*all")
        file:close()
    end
    return content, error
end

---Get the hardware information of the device
---@param hardware_info_path string Path to the hardware info file
---@return table hardware_info {model: string, revision: string}
---@return string|nil error
local function get_hardware_info(hardware_info_path)
    -- Can expand this function to also collect information about individual components
    local hardware_info = {
        model = nil,
        revision = nil
    }
    local info, error = read_file(hardware_info_path, true)
    if info then
        hardware_info.model, hardware_info.revision = info:match("^(%S+)%s+(%S+)")
        return hardware_info, nil
    end
    return hardware_info, error
end

---Get the MAC address of the device
---@param mac_address_path string Path to the mac address file
---@return string|nil mac_address
---@return string|nil err
local function get_parsed_mac(mac_address_path)
    local mac_address, err = read_file(mac_address_path, true)
    if mac_address then
        return mac_address:gsub(":", ""):match("^%s*(.-)%s*$"), nil
    end
    return nil, err
end

---Find the hwmon directory for a given device name
---@param device_name string The name to match in /sys/class/hwmon/*/name
---@return string|nil hwmon_path The hwmon directory path
---@return string|nil error
local function find_hwmon_device(device_name)
    local output, err = exec.command("sh", "-c",
        "grep -rl '^" .. device_name .. "$' /sys/class/hwmon/*/name 2>/dev/null"):output()
    if err or #output == 0 then
        return nil, "hwmon device '" .. device_name .. "' not found"
    end

    -- output is e.g. /sys/class/hwmon/hwmon2/name — extract directory
    local name_path = output:match("^(%S+)")
    if not name_path then
        return nil, "hwmon device '" .. device_name .. "' not found"
    end
    local hwmon_path = name_path:match("(.+)/name$")
    if not hwmon_path then
        return nil, "could not parse hwmon path from: " .. name_path
    end
    return hwmon_path, nil
end

---Check if the fan controller is present and readable
---Tries both "pwmfan" and "rpipoefan" as the device name varies by OpenWrt version
---@return table|nil fan_status {hwmon_path, pwm}
---@return string|nil error
local function get_fan_status()
    local hwmon_path, find_err = find_hwmon_device("pwmfan")
    if find_err then
        hwmon_path, find_err = find_hwmon_device("rpipoefan")
    end
    if find_err then
        return nil, find_err
    end

    local pwm_path = hwmon_path .. "/pwm1"
    local pwm_str = read_file(pwm_path, true)
    local pwm = 0
    if pwm_str then
        pwm = tonumber(pwm_str:match("^%s*(.-)%s*$")) or 0
    end

    return {
        hwmon_path = hwmon_path,
        pwm = pwm,
    }, nil
end

return {
    is_process_running = is_process_running,
    is_service_running = is_service_running,
    file_exists = file_exists,
    get_installed_packages = get_installed_packages,
    get_hardware_info = get_hardware_info,
    get_parsed_mac = get_parsed_mac,
    find_hwmon_device = find_hwmon_device,
    get_fan_status = get_fan_status,
}
