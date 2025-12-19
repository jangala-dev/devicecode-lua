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
    -- Minimal mmcli -J -m output containing only the fields the
    -- modem driver (and mode/model overrides) actually read.
    local base_information = {
        modem = {
            ["3gpp"] = {
                ["registration-state"] = "--",
            },
            generic = {
                -- Drivers determine QMI/MBIM mode
                drivers = {
                    "qmi_wwan",
                },
                -- Used to select manufacturer/model mapping
                plugin = "quectel",
                model = "QUECTEL Mobile Broadband Module",
                revision = "EG25GGBR07A08M2G",

                -- Identity
                ["equipment-identifier"] = "867929068986654",
                device = "/sys/devices/platform/axi/1000120000.pcie/1f00300000.usb/xhci-hcd.1/usb3/3-1",

                -- Ports used for QMI, AT and net stats
                ports = {
                    "cdc-wdm0 (qmi)",
                    "ttyUSB2 (at)",
                    "wwan0 (net)",
                },
                ["primary-port"] = "cdc-wdm0",

                -- SIM / state used by the driver polling logic
                sim = "--",
                state = "disabled",
            },
        },
    }
    local merged = merge_tables(base_information, overrides or {})

    return json.encode(merged), merged
end

-- Minimal mmcli -J -i <sim> output structure. The driver only
-- requires the top-level `sim` table, so we keep this very small
-- while allowing overrides for tests that care about details.
local function make_sim_information(overrides)
    local base_information = {
        sim = {
            ["active"] = true,
            ["imsi"] = "001010123456789",
            ["operator-id"] = "00101",
            ["operator-name"] = "Test Operator",
        },
    }
    local merged = merge_tables(base_information, overrides or {})
    return json.encode(merged), merged
end

-- Minimal mmcli --signal-get JSON. You can select one or more
-- access technologies that should carry real values via
-- `active_techs`; all other technologies have their metrics set
-- to "--" by default.
--
-- active_techs: either a single string ("lte") or an array of
--                tech strings (e.g. {"lte", "5g"}). Allowed
--                values are "5g", "cdma1x", "evdo", "gsm",
--                "lte", "umts".
-- overrides: optional table keyed by tech name, each value a
--            table merged into that tech's metrics.
local function make_signal_information(active_techs, overrides)
    local base_signal = {
        modem = {
            signal = {
                ["5g"] = {
                    ["error-rate"] = "--",
                    rsrp = "--",
                    rsrq = "--",
                    snr = "--",
                },
                cdma1x = {
                    ecio = "--",
                    ["error-rate"] = "--",
                    rssi = "--",
                },
                evdo = {
                    ecio = "--",
                    ["error-rate"] = "--",
                    io = "--",
                    rssi = "--",
                    sinr = "--",
                },
                gsm = {
                    ["error-rate"] = "--",
                    rssi = "--",
                },
                lte = {
                    ["error-rate"] = "--",
                    rsrp = "--",
                    rsrq = "--",
                    rssi = "--",
                    snr = "--",
                },
                umts = {
                    ecio = "--",
                    ["error-rate"] = "--",
                    rscp = "--",
                    rssi = "--",
                },
                refresh = {
                    rate = "0",
                },
                threshold = {
                    ["error-rate"] = "no",
                    rssi = "0",
                },
            },
        },
    }

    -- Normalise active_techs to an array of tech names
    local tech_list
    if type(active_techs) == "string" or active_techs == nil then
        tech_list = { active_techs or "lte" }
    elseif type(active_techs) == "table" then
        tech_list = active_techs
    else
        tech_list = { "lte" }
    end

    overrides = overrides or {}

    for _, tech in ipairs(tech_list) do
        local tech_table = base_signal.modem.signal[tech]
        if tech_table then
            local tech_overrides = overrides[tech] or overrides
            if tech_overrides and next(tech_overrides) ~= nil then
                base_signal.modem.signal[tech] = merge_tables(tech_table, tech_overrides)
            end
        end
    end

    local encoded = json.encode(base_signal)
    return encoded, base_signal
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
    make_sim_information = make_sim_information,
    make_signal_information = make_signal_information,
    make_modem_device_event = make_modem_device_event,
    merge_tables = merge_tables,
}
