local modem_types = require 'services.hal.types.modem'
local qmi = require 'services.hal.backends.modem.modes.qmi'
local exec = require 'fibers.io.exec'
local op = require 'fibers.op'
local runfibers = require 'tests.support.run_fibers'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end end

local function network_backend()
	local Backend = {}
	function Backend:read_network_info()
		return modem_types.new.ModemNetworkInfo('O2', { 'lte' }, nil, nil, nil)
	end
	function Backend:read_sim_info()
		return nil, 'unused'
	end
	qmi.add_mode_funcs(Backend)
	return setmetatable({ identity = { mode_port = '/dev/cdc-wdm0' } }, { __index = Backend })
end

local function with_qmi_results(results, fn)
	local original_command = exec.command
	local next_result = 1
	exec.command = function()
		local result = assert(results[next_result], 'unexpected qmicli command')
		next_result = next_result + 1
		return {
			combined_output_op = function()
				return op.always(
					result.output or '', result.status or 'exited', result.code or 0, nil, result.err)
			end,
		}
	end
	local success, err = xpcall(function() runfibers.run(fn) end, debug.traceback)
	exec.command = original_command
	if not success then error(err, 0) end
end

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

function tests.test_qmi_keeps_home_network_when_rf_band_command_fails()
	local info, err
	with_qmi_results({
		{ output = "MCC: '234'\nMNC: '10'\n" },
		{ output = 'error', code = 1, err = 'radio unavailable' },
	}, function()
		info, err = network_backend():read_network_info()
	end)
	ok(info, err)
	eq(err, '')
	eq(info.mcc, '234')
	eq(info.mnc, '10')
	eq(info.active_band_class, nil)
end

function tests.test_qmi_keeps_home_network_when_rf_band_is_absent_from_output()
	local info, err
	with_qmi_results({
		{ output = "MCC: '234'\nMNC: '10'\n" },
		{ output = 'Successfully got RF band info, but no active band' },
	}, function()
		info, err = network_backend():read_network_info()
	end)
	ok(info, err)
	eq(err, '')
	eq(info.mcc, '234')
	eq(info.mnc, '10')
	eq(info.active_band_class, nil)
end

function tests.test_qmi_home_network_failure_remains_fatal()
	local info, err
	with_qmi_results({
		{ output = 'error', code = 1, err = 'modem unavailable' },
	}, function()
		info, err = network_backend():read_network_info()
	end)
	eq(info, nil)
	ok(err and err ~= '', 'home-network failure must still be returned')
end

return tests
