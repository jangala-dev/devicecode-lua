local json = require('dkjson')

local function merge_tables(main, overrides)
    local result = {}
    for k, v in pairs(main) do
        result[k] = v
    end
    for k, v in pairs(overrides) do
        if type(v) == 'table' and type(result[k]) == 'table' then
            result[k] = merge_tables(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

local function make_modem_information(overrides)
    local base_information = {
        modem = {
            ["3gpp"] = {
                ["5gnr"] = {
                    ["registration-settings"] = {
                        ["drx-cycle"] = "--",
                        ["mico-mode"] = "--",
                    },
                },
                ["enabled-locks"] = {
                    "fixed-dialing",
                },
                eps = {
                    ["initial-bearer"] = {
                        ["dbus-path"] = "--",
                        settings = {
                            apn = "",
                            ["ip-type"] = "ipv4v6",
                            password = "--",
                            user = "--",
                        },
                    },
                    ["ue-mode-operation"] = "csps-2",
                },
                imei = "867929068986654",
                ["operator-code"] = "--",
                ["operator-name"] = "--",
                ["packet-service-state"] = "--",
                pco = "--",
                ["registration-state"] = "--",
            },
            cdma = {
                ["activation-state"] = "--",
                ["cdma1x-registration-state"] = "--",
                esn = "--",
                ["evdo-registration-state"] = "--",
                meid = "--",
                nid = "--",
                sid = "--",
            },
            ["dbus-path"] = "/org/freedesktop/ModemManager1/Modem/14",
            generic = {
                ["access-technologies"] = {},
                bearers = {},
                ["carrier-configuration"] = "ROW_Generic_3GPP",
                ["carrier-configuration-revision"] = "0501081F",
                ["current-bands"] = {
                    "egsm",
                    "dcs",
                    "pcs",
                    "g850",
                    "utran-1",
                    "utran-4",
                    "utran-6",
                    "utran-5",
                    "utran-8",
                    "utran-2",
                    "eutran-1",
                    "eutran-2",
                    "eutran-3",
                    "eutran-4",
                    "eutran-5",
                    "eutran-7",
                    "eutran-8",
                    "eutran-12",
                    "eutran-13",
                    "eutran-18",
                    "eutran-19",
                    "eutran-20",
                    "eutran-25",
                    "eutran-26",
                    "eutran-28",
                    "eutran-38",
                    "eutran-39",
                    "eutran-40",
                    "eutran-41",
                    "utran-19",
                },
                ["current-capabilities"] = {
                    "gsm-umts, lte",
                },
                ["current-modes"] = "allowed: 2g, 3g, 4g; preferred: 4g",
                device = "/sys/devices/platform/axi/1000120000.pcie/1f00300000.usb/xhci-hcd.1/usb3/3-1",
                ["device-identifier"] = "a7591502473ae9ffc14e992ff1621f18cc4dd408",
                drivers = {
                    "option1",
                    "qmi_wwan",
                },
                ["equipment-identifier"] = "867929068986654",
                ["hardware-revision"] = "10000",
                manufacturer = "QUALCOMM INCORPORATED",
                model = "QUECTEL Mobile Broadband Module",
                ["own-numbers"] = {},
                physdev = "/sys/devices/platform/axi/1000120000.pcie/1f00300000.usb/xhci-hcd.1/usb3/3-1",
                plugin = "quectel",
                ports = {
                    "cdc-wdm0 (qmi)",
                    "ttyUSB0 (ignored)",
                    "ttyUSB1 (gps)",
                    "ttyUSB2 (at)",
                    "ttyUSB3 (at)",
                    "wwan0 (net)",
                },
                ["power-state"] = "on",
                ["primary-port"] = "cdc-wdm0",
                ["primary-sim-slot"] = "1",
                revision = "EG25GGBR07A08M2G",
                ["signal-quality"] = {
                    recent = "yes",
                    value = "0",
                },
                sim = "--",
                ["sim-slots"] = {
                    "/org/freedesktop/ModemManager1/SIM/14",
                    "/",
                },
                state = "disabled",
                ["state-failed-reason"] = "--",
                ["supported-bands"] = {
                    "egsm",
                    "dcs",
                    "pcs",
                    "g850",
                    "utran-1",
                    "utran-4",
                    "utran-6",
                    "utran-5",
                    "utran-8",
                    "utran-2",
                    "eutran-1",
                    "eutran-2",
                    "eutran-3",
                    "eutran-4",
                    "eutran-5",
                    "eutran-7",
                    "eutran-8",
                    "eutran-12",
                    "eutran-13",
                    "eutran-18",
                    "eutran-19",
                    "eutran-20",
                    "eutran-25",
                    "eutran-26",
                    "eutran-28",
                    "eutran-38",
                    "eutran-39",
                    "eutran-40",
                    "eutran-41",
                    "utran-19",
                },
                ["supported-capabilities"] = {
                    "gsm-umts, lte",
                },
                ["supported-ip-families"] = {
                    "ipv4",
                    "ipv6",
                    "ipv4v6",
                },
                ["supported-modes"] = {
                    "allowed: 2g; preferred: none",
                    "allowed: 3g; preferred: none",
                    "allowed: 4g; preferred: none",
                    "allowed: 2g, 3g; preferred: 3g",
                    "allowed: 2g, 3g; preferred: 2g",
                    "allowed: 2g, 4g; preferred: 4g",
                    "allowed: 2g, 4g; preferred: 2g",
                    "allowed: 3g, 4g; preferred: 4g",
                    "allowed: 3g, 4g; preferred: 3g",
                    "allowed: 2g, 3g, 4g; preferred: 4g",
                    "allowed: 2g, 3g, 4g; preferred: 3g",
                    "allowed: 2g, 3g, 4g; preferred: 2g",
                },
                ["unlock-required"] = "sim-pin2",
                ["unlock-retries"] = {
                    "sim-pin (3)",
                    "sim-puk (10)",
                    "sim-pin2 (3)",
                    "sim-puk2 (10)",
                },
            },
        },
    }
    local merged = merge_tables(base_information, overrides or {})

    return json.encode(merged), merged
end

local function make_modem_device_event(overrides)
    local base_event = {
        connected = false,
        data = {
            device = "modemcard",
            port = "/sys/devices/platform/axi/1000120000.pcie/1f00300000.usb/xhci-hcd.1/usb3/3-1"
        },
        id_field = "port",
        type = "usb"
    }
    if overrides and overrides.connected == true then
        base_event.capabilities = {
            modem = {
                control = {
                    driver_q = {
                        buffer = { count = 0, first = 1, items = {} },
                        buffer_size = 10,
                        getq = { count = 0, first = 1, items = {} },
                        putq = { count = 0, first = 1, items = {} }
                    }
                },
                id = "867929068986654"
            }
        }
        base_event.device_control = {}
    end
    return merge_tables(base_event, overrides or {})
end

return {
    make_modem_information = make_modem_information,
    make_modem_device_event = make_modem_device_event,
}
