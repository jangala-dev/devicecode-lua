local CONSTANTS = require 'constants'

local getbox_packages_installed = {
    "mwan3",
    "rpcd",
    "sqm-scripts",
    "lua-lumen",
    "modemmanager",
    "qmi-utils",
    "usb-modeswitch",
    "kmod-mii",
    "kmod-usb-wdm",
    "kmod-usb-serial",
    "kmod-usb-net",
    "kmod-usb-serial-wwan",
    "kmod-usb-serial-option",
    "kmod-usb-net-qmi-wwan",
    "swupdate",
    "lua",
    "luasocket",
    "luaposix",
    "dkjson",
    "curl",
    "lua-bit32",
    "lua-popen3",
    "luci-lib-nixio",
    "libuci-lua",
    "libubus-lua",
    "libiwinfo-lua",
    "lua-http",
    "lua-cqueues",
    "lmdb",
    "lua-compat53",
    "jq",
    "block-mount"
}

local bigbox_packages_installed = {
    "mwan3",
    "rpcd",
    "sqm-scripts",
    "lua-lumen",
    "kmod-hwmon-rpi-poe-fan",
    "kmod-i2c-core",
    "block-mount",
    "kmod-fs-ext4",
    "btrfs-progs",
    "kmod-fs-btrfs",
    "fdisk",
    "modemmanager",
    "qmi-utils",
    "mbim-utils",
    "usb-modeswitch",
    "kmod-mii",
    "kmod-usb-wdm",
    "kmod-usb-serial",
    "kmod-usb-net",
    "kmod-usb-serial-wwan",
    "kmod-usb-serial-option",
    "kmod-usb-net-qmi-wwan",
    "kmod-usb-net-cdc-mbim",
    "atinout",
    "swupdate",
    "lua",
    "luasocket",
    "luaposix",
    "dkjson",
    "curl",
    "lua-bit32",
    "lua-popen3",
    "luci-lib-nixio",
    "libuci-lua",
    "libubus-lua",
    "libiwinfo-lua",
    "lua-http",
    "lua-cqueues",
    "lmdb",
    "lmdb-test",
    "lua-compat53",
    "usbutils",
    "tree",
    "uhubctl",
    "jq"
}

local getbox_modems = 1

local bigbox_modems = 2

local bootstrap_installed = {
    "/data/configs/hawkbit.cfg",
    "/data/configs/mainflux.cfg",
    "/data/serial",
}

local packages_running = {
    "ModemManager",
    "devicecode",
    "ui",
    "swupdate",
    "mwan3"
}

local getbox_services_running = {
    "dnsmasq",
    "dropbear",
    "log",
    "modemmanager",
    "mwan3",
    "network",
    "odhcpd",
    "rpcd",
    "sysntpd",
    "urngd",
    "wpad"
}

local bigbox_services_running = {
    "dnsmasq",
    "dropbear",
    "log",
    "modemmanager",
    "mwan3",
    "network",
    "odhcpd",
    "rpcd",
    "sysntpd",
    "wpad"
}

---Get the expected packages installed for the box type
---@param box_type string getbox|bigbox
---@return string[] expected_packages_installed
---@return string|nil error
local function get_expected_packages_installed(box_type)
    if box_type == CONSTANTS.GETBOX then
        return getbox_packages_installed, nil
    elseif box_type == CONSTANTS.BIGBOX then
        return bigbox_packages_installed, nil
    else
        return {}, "Unknown box type: " .. box_type
    end
end

---Get the expected services running for the box type
---@param box_type string getbox|bigbox
---@return string[] expected_services_running
---@return string|nil error
local function get_expected_services_running(box_type)
    if box_type == CONSTANTS.GETBOX then
        return getbox_services_running, nil
    elseif box_type == CONSTANTS.BIGBOX then
        return bigbox_services_running, nil
    else
        return {}, "Unknown box type: " .. box_type
    end
end

---Get the number of expected modems installed for the box model
---@param box_type string getbox|bigbox
---@return number expected_modems
---@return string|nil error
local function get_expected_modem_count(box_type)
    if box_type == CONSTANTS.GETBOX then
        return getbox_modems, nil
    elseif box_type == CONSTANTS.BIGBOX then
        return bigbox_modems, nil
    else
        return 0, "Unknown box_type: " .. box_type
    end
end

return {
    packages_running = packages_running,
    bootstrap_installed = bootstrap_installed,
    get_expected_packages_installed = get_expected_packages_installed,
    get_expected_services_running = get_expected_services_running,
    get_expected_modem_count = get_expected_modem_count,
    config_files = config_files,
}
