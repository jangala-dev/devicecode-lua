#!/usr/bin/env luajit
local stdlib = require 'posix.stdlib'
local unistd = require 'posix.unistd'
local path = assert(stdlib.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/modem_startup$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path

local runner = require 'onbox.modem_startup.runner'
local util = require 'onbox.support.util'
local tests = {}

local imei, secondary = '123456', '654321'
local function config(autoconnect)
	return { gsm = { data = { modems = {
		default = { name = 'ignored default name', autoconnect = autoconnect },
		known = { { id_field = 'device', device = 'slot-1', name = 'primary' },
			{ id_field = 'device', device = 'slot-2', name = 'secondary', enabled = false },
			{ id_field = 'device', device = 'slot-3', autoconnect = false } },
	} } } }
end

local function log(label, state, event)
	return 'daemon.info devicecode: 2026-11-20 11:00:00 (mono=17.125)  LOG  gsm  info  '
		.. (event or 'modem_state_changed') .. '  ' .. label .. ' modem state -> ' .. state
end

function tests.selects_all_autoconnect_modems_and_rejects_an_unavailable_target()
	local target = { imei = imei, device = 'slot-1', state = 'disabled' }
	local other = { imei = secondary, device = 'slot-2', state = 'connected' }
	local manual = { imei = '8675309', device = 'slot-3', state = 'connected' }
	local inventory = { [imei] = target, [secondary] = other, [manual.imei] = manual }
	local selected = runner.select_targets(config(true), inventory)
	assert(selected[imei].label == 'primary …3456' and selected[secondary].label == 'secondary …4321')
	assert(not selected[manual.imei])
	selected = runner.select_targets(config(true), inventory, imei)
	assert(selected[imei] and not selected[secondary])
	assert(not pcall(runner.select_targets, config(false), inventory, imei))
	target.device = 'unconfigured-device'
	assert(runner.select_targets(config(true), inventory, imei)[imei].label == imei .. ' …3456')
	other.state = 'locked'
	assert(not pcall(runner.select_targets, config(true), inventory))
end

function tests.parser_only_accepts_state_events_for_the_target()
	local matched = assert(runner.parse_transition(log('primary …3456', 'registered'), 'primary …3456'))
	assert(matched.state == 'registered' and matched.monotonic_s == 17.125)
	assert(not runner.parse_transition(log('secondary …3456', 'connected'), 'primary …3456'))
	assert(not runner.parse_transition(log('primary …3456', 'connected', 'gsm_summary'), 'primary …3456'))
	assert(runner.parse_transition(log('primary …3456', 'failed', 'modem_failed'), 'primary …3456').state == 'failed')
end

local function fixture(options)
	local directory = assert(stdlib.mkdtemp('/tmp/onbox-startup-XXXXXX'))
	local state = { running = not options.stopped, modem = options.stopped and 'disabled' or 'connected',
		id = '7', starts = 0, disables = 0, strict_reads = 0 }
	if options.multiple then state.other = 'connected' end
	local box = { args = { timeout = 30 }, artifacts = directory }
	local instance = runner.from_session(box)
	box.run = function(_, body, hooks)
		local ok, err = pcall(body)
		if not ok then state.err = tostring(err); hooks.diagnostics() end
		hooks.restore()
		return ok and 0 or 1
	end
	box.phase = function(_, _, body) body() end
	box.ssh = { run = function(_, command)
		assert(not state.running)
		state.disables = state.disables + 1
		if command == 'mmcli -m 9 --disable' and state.other then
			state.other = 'disabled'
		else
			assert(command == 'mmcli -m ' .. state.id .. ' --disable')
			state.modem = 'disabled'
		end
	end }
	box.logs = {
		checkpoint = function(_, _, observer)
			if options.drops_at_end and not observer and state.observe then
				state.observe(log('primary …3456', 'failed', 'modem_failed'))
				state.modem = 'failed'
			end
			state.observe = observer
			if observer then
				assert(not observer(log('primary …3456', 'connected')), 'a pre-start event was accepted')
				if options.baseline_lost then state.modem = 'connected' end
			end
		end,
		wait_for = function(_, description, _, check) return assert(check(), description) end,
		diagnostics = function() state.diagnosed = true end,
	}
	local function inventory(_, strict)
		if strict then state.strict_reads = state.strict_reads + 1 end
		local modems = { [imei] = { imei = imei, id = state.id, state = state.modem, device = 'slot-1' } }
		if state.other then
			modems[secondary] = { imei = secondary, id = '9', state = state.other, device = 'slot-2' }
		end
		return modems
	end
	instance.modems = {
		inventory = inventory,
		wait = function(_, targets, expected)
			local modems = inventory()
			for key in pairs(targets) do assert(modems[key].state == expected, 'hardware did not reach ' .. expected) end
			return modems
		end,
		diagnostic_commands = function() return {} end,
	}
	instance.runtime = {
		original = config(true), prepare = function() end, ensure_dependencies = function() end,
		service_pids = function() return state.running and { ['9'] = true } or {} end,
		backup = function() state.backed_up = true end,
		build = function() assert(state.backed_up); return 'build.tar.gz' end,
		deploy = function(self) self.changed, state.running = true, false end,
		write_config = function(_, effective) assert(effective.gsm.data.modems.default.autoconnect) end,
		service = function(_, action)
			assert(action == 'start' and not state.running)
			state.starts, state.running = state.starts + 1, true
			if state.restored then return end
			assert(state.modem == 'disabled' and state.observe, 'startup was not armed from disabled')
			state.observe(log('primary …3456', 'enabling'))
			state.id = '8' -- A startup reset can replace the ModemManager object.
			state.observe(log('primary …3456', 'registered'))
			state.observe(log(options.wrong_target and 'other …9999' or 'primary …3456', 'connected'))
			state.modem = options.no_connection and 'registered' or 'connected'
			if state.other then
				assert(state.other == 'disabled')
				state.observe(log('secondary …4321', 'registered'))
				if not options.no_other_event then state.observe(log('secondary …4321', 'connected')) end
				state.other = options.other_not_connected and 'registered' or 'connected'
			end
		end,
		restore_runtime = function() state.restored, state.running = true, false end,
		diagnostic_commands = function() return {} end,
	}
	local code = instance:run()
	local result = util.decode(util.read(directory .. '/results.json'))
	assert(os.remove(directory .. '/results.json'))
	assert(unistd.rmdir(directory))
	return code, state, result
end

function tests.starts_from_disabled_records_transitions_and_restores()
	local code, state, result = fixture({ multiple = true })
	assert(code == 0 and state.restored and state.running and state.starts == 2 and state.disables == 2)
	assert(state.strict_reads == 3)
	local primary, other = result.modems[imei], result.modems[secondary]
	assert(primary.transitions[1].state == 'disabled' and primary.transitions[1].source == 'mmcli')
	assert(primary.transitions[2].state == 'enabling' and primary.transitions[3].state == 'registered')
	assert(primary.transitions[4].state == 'connected' and primary.confirmed_state == 'connected')
	assert(other.transitions[1].state == 'disabled' and other.transitions[2].state == 'registered')
	assert(other.transitions[3].state == 'connected' and other.confirmed_state == 'connected')
end

function tests.originally_stopped_service_and_disabled_modem_are_left_that_way()
	local code, state = fixture({ stopped = true })
	assert(code == 0 and state.restored and not state.running and state.starts == 1 and state.modem == 'disabled')
end

function tests.missing_gsm_evidence_or_hardware_confirmation_fails_and_restores()
	for _, options in ipairs({ { wrong_target = true }, { no_connection = true },
		{ baseline_lost = true }, { drops_at_end = true } }) do
		local code, state, result = fixture(options)
		assert(code == 1 and state.restored and state.running and state.diagnosed)
		assert(result.modems[imei].confirmed_state == nil)
		if options.baseline_lost then assert(state.starts == 1 and state.err:find('no longer disabled', 1, true)) end
	end
end

function tests.run_fails_if_only_one_of_two_modems_passes()
	for _, options in ipairs({ { multiple = true, no_other_event = true },
		{ multiple = true, other_not_connected = true } }) do
		local code, state, result = fixture(options)
		assert(code == 1 and state.restored and state.diagnosed)
		assert(result.modems[secondary].confirmed_state == nil)
	end
end

local names = util.keys(tests)
for _, name in ipairs(names) do
	tests[name]()
	print('PASS ' .. name)
end
print(('%d modem startup runner tests passed'):format(#names))
