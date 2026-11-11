local modem_types = require 'services.hal.types.modem'
local qmi = require 'services.hal.backends.modem.modes.qmi'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end end

function tests.test_qmi_preserves_sim_fields_when_gid1_read_fails()
	local info, err = modem_types.new.ModemSimInfo(
		'/org/freedesktop/ModemManager1/SIM/2',
		'8944',
		'23415',
		nil,
		'sim-pin',
		{ ['sim-pin'] = 3, ['sim-puk'] = 10 },
		'locked'
	)
	ok(info, err)

	local enriched, enrich_err = qmi._test.sim_info_with_qmi_fields(
		info, 'giffgaff', '', nil, 'locked SIM cannot read gid1')
	ok(enriched, enrich_err)
	eq(enriched.spn, 'giffgaff')
	eq(enriched.gid1, nil)
	eq(enriched.sim_lock, 'sim-pin')
	eq(enriched.sim_lock_retries['sim-pin'], 3)
	eq(enriched.modem_state, 'locked')
end

function tests.test_qmi_parses_service_provider_name_for_mvno_apns()
	local spn, err = qmi._test.parse_spn([[
[/dev/cdc-wdm0] Successfully got operator name data
Service Provider Name
	Display Condition: 'display-condition-0'
	Name             : 'giffgaff'
Operator Name: 'O2 - UK'
]])
	eq(err, '')
	eq(spn, 'giffgaff')
end

function tests.test_qmi_spn_parser_does_not_use_network_operator_name()
	local spn, err = qmi._test.parse_spn([[
[/dev/cdc-wdm0] Successfully got operator name data
Operator Name: 'O2 - UK'
NITZ information:
	Long Name:  'O2 - UK'
]])
	eq(spn, nil)
	ok(err:find('Service Provider Name', 1, true), err)
end

return tests
