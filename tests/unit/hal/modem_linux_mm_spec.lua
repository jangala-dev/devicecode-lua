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

return tests
