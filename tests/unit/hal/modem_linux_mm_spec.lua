local linux_mm = require 'services.hal.backends.modem.providers.linux_mm.impl'
local exec = require 'fibers.io.exec'
local fibers = require 'fibers'
local op = require 'fibers.op'
local json = require 'cjson.safe'
local safe = require 'coxpcall'
local runfibers = require 'tests.support.run_fibers'
local driver = require 'services.hal.drivers.modem'
local sleep = require 'fibers.sleep'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end end

---@return nil
function tests.test_linux_mm_stopped_state_monitor_reports_command_closed()
	runfibers.run(function()
		local backend = setmetatable({}, linux_mm._test.ModemBackend)
		local event, err = fibers.perform(backend:monitor_state_op())
		eq(event, nil)
		eq(err, 'Command closed')
	end)
end

---@return nil
function tests.test_linux_mm_lifecycle_exits_when_state_monitor_is_cleared_during_shutdown()
	runfibers.run(function()
		local backend = setmetatable({
			state_monitor = { stream = { read_line_op = function()
				return op.always("modem: Initial state, 'disabled'")
			end } },
			wait_for_sim_present_op = function() return sleep.sleep_op(math.huge) end,
		}, linux_mm._test.ModemBackend)
		local errors = {}
		local modem = assert(driver.new('test-modem', {
			debug = function() end,
			trace = function() end,
			error = function(_, entry)
				errors[#errors + 1] = entry
				assert(#errors == 1, 'Lifecycle spins on a cleared state monitor without yielding')
			end,
		}))
		modem.backend = backend
		modem._emit_state = function()
			-- Shutdown clears the monitor before yielding to wait for its process.
			backend.state_monitor = nil
		end
		modem:modem_lifecycle_monitor()
		eq(#errors, 1)
		eq(errors[1].what, 'state monitor_closed')
	end)
end

---@return nil
function tests.test_linux_mm_constructor_prefers_secondary_at_port_with_primary_fallback()
	local saved = exec.command
	local success, err = safe.pcall(function()
		for _, secondary in ipairs({ true, false }) do
			local ports = { 'cdc-wdm1 (qmi)', 'ttyUSB6 (at)', 'wwan1 (net)' }
			if secondary then ports[#ports + 1] = 'ttyUSB7 (at)' end
			local output = assert(json.encode({ modem = { generic = {
				['equipment-identifier'] = '860195058017887',
				device = '/sys/devices/demo', ports = ports,
			} } }))
			exec.command = function(args)
				eq(args[1], 'mmcli')
				eq(args[2], '-J')
				eq(args[3], '-m')
				eq(args[4], '1')
				return { combined_output_op = function()
					return op.always(output, 'exited', 0)
				end }
			end
			runfibers.run(function()
				local identity = linux_mm.new('1').identity
				eq(identity.at_port, secondary and '/dev/ttyUSB7' or '/dev/ttyUSB6')
				eq(identity.mode_port, '/dev/cdc-wdm1')
				eq(identity.net_port, 'wwan1')
			end)
		end
	end)
	exec.command = saved
	assert(success, err)
end

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
