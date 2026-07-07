local modem_types = require 'services.hal.types.modem'
local qmi = require 'services.hal.backends.modem.modes.qmi'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end end

function tests.test_qmi_preserves_sim_lock_when_gid1_read_fails()
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

	local enriched, enrich_err = qmi._test.sim_info_with_gid1(info, nil, 'locked SIM cannot read gid1')
	ok(enriched, enrich_err)
	eq(enriched.gid1, nil)
	eq(enriched.sim_lock, 'sim-pin')
	eq(enriched.sim_lock_retries['sim-pin'], 3)
	eq(enriched.modem_state, 'locked')
end

return tests
