local modem_types = require 'services.hal.types.modem'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end end

function tests.test_modem_signal_info_accepts_technology_keyed_numeric_values()
	local info, err = modem_types.new.ModemSignalInfo({
		lte = { rsrp = -97, rsrq = -11.5 },
		['5g'] = { rsrp = -103, snr = 0 },
	})
	ok(info, err)
	eq(info.values.lte.rsrp, -97)
	eq(info.values['5g'].snr, 0)
end

function tests.test_modem_signal_info_rejects_legacy_flat_values()
	local info, err = modem_types.new.ModemSignalInfo({ rsrp = -97 })
	eq(info, nil)
	eq(err, 'invalid signal values')
end

function tests.test_modem_signal_info_rejects_non_numeric_measurements()
	local info, err = modem_types.new.ModemSignalInfo({
		lte = { rsrp = '-97' },
	})
	eq(info, nil)
	eq(err, 'invalid signal values')
end

function tests.test_modem_signal_info_accepts_empty_signal_set_as_observed_absence()
	local empty_info, empty_err = modem_types.new.ModemSignalInfo({})
	ok(empty_info, empty_err)
	eq(next(empty_info.values), nil)

	local empty_tech_info, empty_tech_err = modem_types.new.ModemSignalInfo({ lte = {} })
	eq(empty_tech_info, nil)
	eq(empty_tech_err, 'invalid signal values')
end

return tests
