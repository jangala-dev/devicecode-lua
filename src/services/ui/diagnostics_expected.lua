local GETBOX="getbox"
local BIGBOX_SS="bigbox-ss"
local BIGBOX_V1_CM="bigbox-v1-cm"

local GETBOX_PACKAGES_INSTALLED = {
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

local BIGBOX_SS_PACKAGES_INSTALLED = {
    "mwan3",
    "rpcd",
    "sqm-scripts",
    "lua-lumen",
    "block-mount",
    "btrfs-progs",
    "kmod-fs-ext4",
    "kmod-fs-btrfs",
    "fdisk",
    "modemmanager",
    "qmi-utils",
    "mbim-utils",
    "libqmi",
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
    "luajit",
    "lua-cjson",
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
    "jq",
}

local BIGBOX_V1_CM_PACKAGES_INSTALLED = {
    -- Core
    "mwan3",
    "rpcd",
    "sqm-scripts",

    -- Fan / hardware monitoring
    "kmod-i2c-core",

    -- Persistent storage
    "block-mount",
    "kmod-fs-ext4",
    "btrfs-progs",
    "kmod-fs-btrfs",
    "fdisk",

    -- Modem / connectivity
    "modemmanager",
    "qmi-utils",
    "mbim-utils",
    "libqmi",
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

    -- Wi-Fi support
    "kmod-mt7915-firmware",
    "kmod-mt7915e",
    "pciutils",
    "dawn",
    "wpad-mbedtls",

    -- Updater
    "swupdate",

    -- Lua runtime
    "lua",
    "luasocket",
    "luaposix",
    "dkjson",
    "curl",
    "lua-bit32",
    "lua-popen3",
    "luci-lib-nixio",
    "luajit",
    "lua-cjson",

    -- Lua bindings
    "libuci-lua",
    "libubus-lua",
    "libiwinfo-lua",

    -- Experimental Lua / internal libs
    "lua-http",
    "lua-cqueues",
    "lmdb",
    "lmdb-test",
    "lua-compat53",

    -- Utilities
    "usbutils",
    "tree",
    "uhubctl",
    "jq",

    -- Bootloader
    "uboot-envtools",
}

local GETBOX_MODEMS = 1
local BIGBOX_SS_MODEMS = 2
local BIGBOX_V1_CM_MODEMS = 2

local BOOTSTRAP_INSTALLED = {
    "/data/configs/hawkbit.cfg",
    "/data/configs/mainflux.cfg",
    "/data/serial",
}

local PACKAGES_RUNNING = {
    "ModemManager",
    "main.lua",
    "swupdate",
    "mwan3"
}

local GETBOX_SERVICES_RUNNING = {
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

local BIGBOX_SS_SERVICES_RUNNING = {
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

local BIGBOX_V1_CM_SERVICES_RUNNING = {
    "dawn",
    "dbus",
    "dnsmasq",
    "dropbear",
    "log",
    "modemmanager",
    "mwan3",
    "network",
    "odhcpd",
    "rpcd",
    "sysntpd",
    "umdns",
    "wpad"
}

local BIGBOX_SS_CONNECTIVITY_TESTS = {
    google   = "test_google_connectivity",
    hawkbit  = "test_hawkbit_connectivity",
    mainflux = "test_mainflux_connectivity",
    unifi    = "test_unifi_connectivity",
}

local BIGBOX_V1_CM_CONNECTIVITY_TESTS = {
    google   = "test_google_connectivity",
    hawkbit  = "test_hawkbit_connectivity",
    mainflux = "test_mainflux_connectivity",
}

local GETBOX_CONNECTIVITY_TESTS = {
    google   = "test_google_connectivity",
    hawkbit  = "test_hawkbit_connectivity",
    mainflux = "test_mainflux_connectivity",
}

local function get_expected_connectivity_tests(box_type)
    if box_type == GETBOX then
        return GETBOX_CONNECTIVITY_TESTS, nil
    elseif box_type == BIGBOX_SS then
        return BIGBOX_SS_CONNECTIVITY_TESTS, nil
    elseif box_type == BIGBOX_V1_CM then
        return BIGBOX_V1_CM_CONNECTIVITY_TESTS, nil
    end

    return {}, "Unknown box type: " .. box_type
end

---Get the expected packages installed for the box type
---@param box_type string getbox|bigbox
---@return string[] expected_packages_installed
---@return string|nil error
local function get_expected_packages_installed(box_type)
    if box_type == GETBOX then
        return GETBOX_PACKAGES_INSTALLED, nil
    elseif box_type == BIGBOX_SS then
        return BIGBOX_SS_PACKAGES_INSTALLED, nil
    elseif box_type == BIGBOX_V1_CM then
        return BIGBOX_V1_CM_PACKAGES_INSTALLED, nil
    else
        return {}, "Unknown box type: " .. box_type
    end
end

---Get the expected services running for the box type
---@param box_type string getbox|bigbox
---@return string[] expected_services_running
---@return string|nil error
local function get_expected_services_running(box_type)
    if box_type == GETBOX then
        return GETBOX_SERVICES_RUNNING, nil
    elseif box_type == BIGBOX_SS then
        return BIGBOX_SS_SERVICES_RUNNING, nil
    elseif box_type == BIGBOX_V1_CM then
        return BIGBOX_V1_CM_SERVICES_RUNNING, nil
    else
        return {}, "Unknown box type: " .. box_type
    end
end

---Get the number of expected modems installed for the box model
---@param box_type string getbox|bigbox
---@return number expected_modems
---@return string|nil error
local function get_expected_modem_count(box_type)
    if box_type == GETBOX then
        return GETBOX_MODEMS, nil
    elseif box_type == BIGBOX_SS then
        return BIGBOX_SS_MODEMS, nil
    elseif box_type == BIGBOX_V1_CM then
        return BIGBOX_V1_CM_MODEMS, nil
    else
        return 0, "Unknown box_type: " .. box_type
    end
end

return {
    packages_running = PACKAGES_RUNNING,
    bootstrap_installed = BOOTSTRAP_INSTALLED,
    get_expected_packages_installed = get_expected_packages_installed,
    get_expected_services_running = get_expected_services_running,
    get_expected_modem_count = get_expected_modem_count,
    get_expected_connectivity_tests = get_expected_connectivity_tests,
}
