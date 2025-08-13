local GETBOX="getbox"
local BIGBOX="bigbox-ss"

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

-- Put quotes around the package names and remove anything after (hyphen and version)
local bigbox_packages_installed = {
    "atinout",
    "base-files",
    "bcm27xx-gpu-fw",
    "bcm27xx-userland",
    "block-mount",
    "brcmfmac-firmware-usb",
    "btrfs-progs",
    "busybox",
    "ca-bundle",
    "curl",
    "cypress-firmware-sdio",
    "cypress-nvram",
    "dbus",
    "dkjson",
    "dnsmasq",
    "dropbear",
    "e2fsprogs",
    "fdisk",
    "firewall4",
    "fstools",
    "fwtool",
    "getrandom",
    "glib2",
    "hostapd",
    "ip",
    "ip6tables",
    "ipset",
    "iptables",
    "iptables-mod-ipopt",
    "iptables-nft",
    "iw",
    "iwinfo",
    "jansson4",
    "jq",
    "jshn",
    "jsonfilter",
    "kernel",
    "kmod-brcmfmac",
    "kmod-brcmutil",
    "kmod-cfg80211",
    "kmod-crypto-acompress",
    "kmod-crypto-crc32c",
    "kmod-crypto-hash",
    "kmod-fixed-phy",
    "kmod-fs-btrfs",
    "kmod-fs-ext4",
    "kmod-fs-vfat",
    "kmod-hid",
    "kmod-hid-generic",
    "kmod-hwmon-core",
    "kmod-hwmon-pwmfan",
    "kmod-hwmon-rpi-poe-fan",
    "kmod-i2c-core",
    "kmod-ifb",
    "kmod-input-core",
    "kmod-input-evdev",
    "kmod-ip6tables",
    "kmod-ipt-conntrack",
    "kmod-ipt-conntrack-extra",
    "kmod-ipt-core",
    "kmod-ipt-ipopt",
    "kmod-ipt-ipset",
    "kmod-ipt-raw",
    "kmod-lib-crc-ccitt",
    "kmod-lib-crc16",
    "kmod-lib-crc32c",
    "kmod-lib-lzo",
    "kmod-lib-raid6",
    "kmod-lib-xor",
    "kmod-lib-zlib-deflate",
    "kmod-lib-zlib-inflate",
    "kmod-lib-zstd",
    "kmod-libphy",
    "kmod-mii",
    "kmod-mmc",
    "kmod-nf-conntrack",
    "kmod-nf-conntrack6",
    "kmod-nf-flow",
    "kmod-nf-ipt",
    "kmod-nf-ipt6",
    "kmod-nf-log",
    "kmod-nf-log6",
    "kmod-nf-nat",
    "kmod-nf-reject",
    "kmod-nf-reject6",
    "kmod-nfnetlink",
    "kmod-nft-compat",
    "kmod-nft-core",
    "kmod-nft-fib",
    "kmod-nft-nat",
    "kmod-nft-offload",
    "kmod-nls-base",
    "kmod-nls-cp437",
    "kmod-nls-iso8859-1",
    "kmod-nls-utf8",
    "kmod-phy-microchip",
    "kmod-ppp",
    "kmod-pppoe",
    "kmod-pppox",
    "kmod-sched-cake",
    "kmod-sched-core",
    "kmod-slhc",
    "kmod-sound-arm-bcm2835",
    "kmod-sound-core",
    "kmod-usb-core",
    "kmod-usb-hid",
    "kmod-usb-net",
    "kmod-usb-net-cdc-ether",
    "kmod-usb-net-cdc-mbim",
    "kmod-usb-net-cdc-ncm",
    "kmod-usb-net-lan78xx",
    "kmod-usb-net-qmi-wwan",
    "kmod-usb-serial",
    "kmod-usb-serial-option",
    "kmod-usb-serial-wwan",
    "kmod-usb-wdm",
    "libattr",
    "libblkid1",
    "libblobmsg-json",
    "libc",
    "libcomerr0",
    "libconfig11",
    "libcurl4",
    "libdbus",
    "libevdev",
    "libexpat",
    "libext2fs2",
    "libf2fs6",
    "libfdisk1",
    "libffi",
    "libgcc1",
    "libipset13",
    "libiptext",
    "libiptext0",
    "libiptext6",
    "libiwinfo-data",
    "libiwinfo-lua",
    "libiwinfo20210430",
    "libjson-c5",
    "libjson-script",
    "liblua5.1.5",
    "liblzo2",
    "libmbim",
    "libmnl0",
    "libmount1",
    "libncurses6",
    "libnftnl11",
    "libnghttp2",
    "libnl",
    "libopenssl1.1",
    "libpcre2",
    "libpthread",
    "libqmi",
    "libqrtr-glib",
    "librt",
    "libsmartcols1",
    "libss2",
    "libubootenv",
    "libubox20220515",
    "libubus-lua",
    "libubus20220601",
    "libuci-lua",
    "libuci20130104",
    "libuclient20201210",
    "libucode20220812",
    "libudev-zero",
    "libusb",
    "libustream-wolfssl20201210",
    "libuuid1",
    "libwolfssl5.7.2.ee39414e",
    "libxtables12",
    "lmdb",
    "lmdb-test",
    "logd",
    "lpeg",
    "lpeg_patterns",
    "lua",
    "lua-basexx",
    "lua-binaryheap",
    "lua-bit32",
    "lua-cjson",
    "lua-compat53",
    "lua-cqueues",
    "lua-fifo",
    "lua-http",
    "lua-lumen",
    "lua-popen3",
    "luajit",
    "luaossl",
    "luaposix",
    "luasocket",
    "luci-lib-nixio",
    "mbim-utils",
    "mkf2fs",
    "modemmanager",
    "mtd",
    "mwan3",
    "netifd",
    "nftables-json",
    "odhcp6c",
    "odhcpd",
    "openwrt-keyring",
    "opkg",
    "partx-utils",
    "ppp",
    "ppp-mod-pppoe",
    "procd",
    "procd-seccomp",
    "procd-ujail",
    "qmi-utils",
    "rpcd",
    "sqm-scripts",
    "swupdate",
    "tc-tiny",
    "terminfo",
    "tree",
    "ubi-utils",
    "ubox",
    "ubus",
    "ubusd",
    "uci",
    "uclient",
    "ucode",
    "ucode-mod-fs",
    "ucode-mod-ubus",
    "ucode-mod-uci",
    "uhubctl",
    "urandom-seed",
    "usb-modeswitch",
    "usbutils",
    "usign",
    "wireless-regdb",
    "wpad-basic-wolfssl",
    "xtables-nft",
    "zlib",
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
    "main.lua",
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
    if box_type == GETBOX then
        return getbox_packages_installed, nil
    elseif box_type == BIGBOX then
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
    if box_type == GETBOX then
        return getbox_services_running, nil
    elseif box_type == BIGBOX then
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
    if box_type == GETBOX then
        return getbox_modems, nil
    elseif box_type == BIGBOX then
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
    get_expected_modem_count = get_expected_modem_count
}
