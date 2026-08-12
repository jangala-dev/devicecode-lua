local linux_mm = require 'services.hal.backends.modem.providers.linux_mm.impl'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end end

function tests.test_linux_mm_parses_sim_lock_fields_from_modem_json()
	local info, err = linux_mm._test.parse_modem_info_json([[
{
  "modem": {
    "3gpp": {
      "imei": "860195058017887",
      "operator-name": "--"
    },
    "generic": {
      "equipment-identifier": "860195058017887",
      "device": "/sys/devices/demo",
      "primary-port": "cdc-wdm1",
      "ports": ["cdc-wdm1 (qmi)", "ttyUSB6 (at)", "wwan1 (net)"],
      "access-technologies": [],
      "sim": "/org/freedesktop/ModemManager1/SIM/1",
      "drivers": ["qmi_wwan", "option1"],
      "plugin": "quectel",
      "model": "QUECTEL Mobile Broadband Module",
      "revision": "EG25GGBR07A08M2G",
      "state": "locked",
      "unlock-required": "sim-puk",
      "unlock-retries": ["sim-pin (0)", "sim-puk (10)", "sim-pin2 (3)"]
    }
  }
}
]])
	ok(info, err)
	eq(info.modem_state, 'locked')
	eq(info.sim_lock, 'sim-puk')
	eq(info.sim_lock_retries['sim-pin'], 0)
	eq(info.sim_lock_retries['sim-puk'], 10)
	eq(info.qmi_ports[1], 'cdc-wdm1')
	eq(info.at_ports[1], 'ttyUSB6')
	eq(info.net_ports[1], 'wwan1')
end

function tests.test_linux_mm_normalises_absent_unlock_required()
	local info, err = linux_mm._test.parse_modem_info_json([[
{
  "modem": {
    "3gpp": {
      "imei": "868549060377253",
      "operator-name": "Demo"
    },
    "generic": {
      "equipment-identifier": "868549060377253",
      "ports": [],
      "access-technologies": "lte",
      "drivers": "qmi_wwan",
      "state": "registered",
      "unlock-required": "--",
      "unlock-retries": []
    }
  }
}
]])
	ok(info, err)
	eq(info.modem_state, 'registered')
	eq(info.sim_lock, nil)
	eq(info.sim_lock_retries, nil)
	eq(info.access_techs[1], 'lte')
	eq(info.drivers[1], 'qmi_wwan')
end

function tests.test_linux_mm_signal_ranges_are_inclusive_and_filter_outside_values()
	local expected_ranges = {
		['5g'] = {
			rssi = { low = -125, high = -30 },
			rsrp = { low = -156, high = -31 },
			rsrq = { low = -43, high = 20 },
			snr = { low = -23, high = 40 },
		},
		cdma1x = {
			rssi = { low = -125, high = -30 },
			ecio = { low = -31.5, high = 0 },
		},
		evdo = {
			rssi = { low = -125, high = -30 },
			ecio = { low = -31.5, high = 0 },
			sinr = { low = -9, high = 9 },
			io = { low = -125, high = -30 },
		},
		gsm = {
			rssi = { low = -125, high = -30 },
		},
		lte = {
			rssi = { low = -125, high = -30 },
			rsrp = { low = -140, high = -44 },
			rsrq = { low = -20, high = -3 },
			snr = { low = -20, high = 30 },
		},
		umts = {
			rssi = { low = -125, high = -30 },
			rscp = { low = -120, high = -25 },
			ecio = { low = -24, high = 0 },
		},
	}

	for tech, expected_signals in pairs(expected_ranges) do
		local actual_signals = linux_mm._test.valid_signal_ranges[tech]
		ok(actual_signals, 'missing ranges for ' .. tech)
		for signal_name, expected in pairs(expected_signals) do
			local actual = actual_signals[signal_name]
			ok(actual, 'missing range for ' .. tech .. '.' .. signal_name)
			eq(actual.low, expected.low)
			eq(actual.high, expected.high)
			eq(linux_mm._test.is_signal_valid(actual.low, actual), true)
			eq(linux_mm._test.is_signal_valid(actual.high, actual), true)
			eq(linux_mm._test.is_signal_valid(actual.low - 0.1, actual), false)
			eq(linux_mm._test.is_signal_valid(actual.high + 0.1, actual), false)
		end
	end
end

function tests.test_linux_mm_signal_parser_returns_all_valid_techs_as_numbers()
	local info, err = linux_mm._test.parse_signal_info_json([[
{
  "modem": {
    "signal": {
      "5g": {
        "rssi": "-80",
        "rsrp": "-103.5",
        "rsrq": "-10",
        "snr": 12.25,
        "error-rate": "99"
      },
      "lte": {
        "rssi": "-70",
        "rsrp": "-96",
        "rsrq": "-11.5",
        "snr": "10"
      },
      "umts": {
        "rscp": "--"
      }
    }
  }
}
]])
	ok(info, err)
	eq(info.values['5g'].rsrp, -103.5)
	eq(info.values['5g'].snr, 12.25)
	eq(info.values['5g']['error-rate'], nil)
	eq(info.values.lte.rsrp, -96)
	eq(info.values.lte.rsrq, -11.5)
	eq(info.values.lte.snr, 10)
	eq(info.values.umts, nil)
end

function tests.test_linux_mm_signal_parser_filters_sentinels_and_invalid_fields()
	local info, err = linux_mm._test.parse_signal_info_json([[
{
  "modem": {
    "signal": {
      "5g": {
        "rssi": "-80",
        "rsrp": "-32768",
        "rsrq": "-10",
        "snr": -3276.8,
        "error-rate": "0"
      },
      "lte": {
        "rsrp": "-97",
        "rsrq": "not-a-number",
        "rssi": "--",
        "snr": "10"
      },
      "gsm": {
        "rssi": "-70"
      },
      "unknown": {
        "rssi": "-50"
      }
    }
  }
}
]])
	ok(info, err)
	eq(info.values['5g'].rssi, -80)
	eq(info.values['5g'].rsrq, -10)
	eq(info.values['5g'].rsrp, nil)
	eq(info.values['5g'].snr, nil)
	eq(info.values.unknown, nil)
	eq(info.values.lte.rsrp, -97)
	eq(info.values.lte.snr, 10)
	eq(info.values.lte.rsrq, nil)
	eq(info.values.lte.rssi, nil)
	eq(info.values.gsm.rssi, -70)
end

function tests.test_linux_mm_signal_parser_preserves_zero()
	local info, err = linux_mm._test.parse_signal_info_json([[
{
  "modem": {
    "signal": {
      "lte": {
        "rssi": "-70",
        "rsrp": "-96",
        "rsrq": "-11.5",
        "snr": 0
      }
    }
  }
}
]])
	ok(info, err)
	eq(info.values.lte.snr, 0)
end

function tests.test_linux_mm_signal_parser_keeps_valid_fields_from_partial_tech()
	local info, err = linux_mm._test.parse_signal_info_json([[
{
  "modem": {
    "signal": {
      "lte": {
        "rssi": "-70",
        "rsrp": "-96",
        "rsrq": "-11.5"
      },
      "gsm": {
        "rssi": "-70"
      }
    }
  }
}
]])
	ok(info, err)
	eq(info.values.lte.rssi, -70)
	eq(info.values.lte.rsrp, -96)
	eq(info.values.lte.rsrq, -11.5)
	eq(info.values.lte.snr, nil)
	eq(info.values.gsm.rssi, -70)
end

function tests.test_linux_mm_signal_parser_reports_empty_success_without_valid_signals()
	local info, err = linux_mm._test.parse_signal_info_json([[
{
  "modem": {
    "signal": {
      "5g": {
        "rsrp": "-32768",
        "error-rate": "0"
      },
      "lte": {
        "rsrp": "--"
      }
    }
  }
}
]])
	ok(info, err)
	eq(next(info.values), nil)
	eq(err, '')
end

return tests
