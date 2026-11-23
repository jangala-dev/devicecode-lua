#!/usr/bin/env luajit
local stdlib = require 'posix.stdlib'
local unistd = require 'posix.unistd'
local path = assert(stdlib.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/modem_autoconnect_off$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path

local runner = require 'onbox.modem_autoconnect_off.runner'
local modem_support = require 'onbox.support.modem'
local util = require 'onbox.support.util'

local primary, secondary = '123456', '654321'
local tests = {}

local function original()
	return { gsm = { rev = 8, data = { modems = {
		default = { autoconnect = true, pdp_type = 'IP' },
		known = { { name = 'primary', id_field = 'device', device = 'slot-1', autoconnect = true },
			{ name = 'secondary', imei = secondary, enabled = true },
			{ name = 'unseen', imei = '911111', autoconnect = true }, false },
	} } } }
end

local function inventory(first, second, state)
	return { [primary] = { id = first, imei = primary, state = state, device = 'slot-1' },
		[secondary] = { id = second, imei = secondary, state = state, device = 'slot-2' } }
end

local function gsm_log(label, state, pid)
	return ('daemon.info sh[%s]: 2026-11-20 11:00:00 (mono=17.125)  LOG  gsm  info  modem_state_changed  ')
		:format(pid or '42')
		.. label .. ' modem state -> ' .. state
end

function tests.overrides_default_and_known_autoconnect_without_mutating_original()
	local config = original()
	local off = runner.phase_config(config)
	assert(config.gsm.rev == 8 and off.gsm.rev == 9)
	local prior, next_config = config.gsm.data.modems, off.gsm.data.modems
	assert(prior.default.autoconnect and prior.known[1].autoconnect and prior.known[3].autoconnect)
	assert(next_config.default.autoconnect == false and next_config.default.pdp_type == 'IP')
	for index = 1, 3 do assert(next_config.known[index].autoconnect == false) end
	assert(next_config.known[4] == false)
	assert(next_config.known[2].enabled and prior.known[2].autoconnect == nil)
	local modems = inventory('7', '8', 'connected')
	local targets = runner.select_targets(config, modems)
	assert(targets[primary].label == 'primary …3456' and targets[secondary].label == 'secondary …4321')
	assert(targets[primary].original_autoconnect and targets[secondary].original_autoconnect)
	modems[secondary] = nil
	assert(not pcall(runner.select_targets, config, modems))
end

function tests.parses_modemmanager_watch_lines()
	local prefix = '\t/org/freedesktop/ModemManager1/Modem/27: '
	local event = assert(modem_support.parse_state_watch(prefix .. "Initial state, 'disabled'"))
	assert(event.object_id == '27' and event.kind == 'initial' and event.state == 'disabled')
	event = assert(modem_support.parse_state_watch(prefix .. "State changed, 'disabled' --> 'enabling' (Reason: User)"))
	assert(event.object_id == '27' and event.kind == 'transition'
		and event.from == 'disabled' and event.state == 'enabling')
	event = assert(modem_support.parse_state_watch(prefix .. 'Removed'))
	assert(event.kind == 'removed' and event.state == 'absent')
	assert(not modem_support.parse_state_watch('unrelated line'))
	event = assert(modem_support.parse_state_syslog('daemon.info [4337]: <info>  [modem27] '
		.. 'state changed (disabled -> enabling)'))
	assert(event.object_id == '27' and event.kind == 'daemon' and event.from == 'disabled' and event.state == 'enabling')
end

local function run(options)
	local directory = assert(stdlib.mkdtemp('/tmp/onbox-autoconnect-off-XXXXXX'))
	local state = { now = 0, watch = {}, inventory_reads = 0 }
	if not options.stopped then state.pid = '40' end
	local prior = inventory('7', '8', 'connected')
	local fresh = inventory('17', options.stale_object and '8' or '18', 'disabled')
	local box = { args = { timeout = 30, observe_seconds = 60 }, artifacts = directory }
	local instance = runner.from_session(box)
	instance.now = function() return state.now end
	box.phase = function(_, _, body) body() end
	box.run = function(_, body, hooks)
		local ok, err = pcall(body)
		if not ok then
			state.err = tostring(err)
			hooks.diagnostics()
		end
		local restored, restore_err = pcall(hooks.restore)
		if not restored then state.err = tostring(restore_err) end
		return ok and restored and 0 or 1
	end
	box.logs = {
		checkpoint = function(_, label, observe)
			if label:match('^BEGIN') then
				assert(not state.pid and state.watch['17'] and state.watch['18'])
				assert(not observe(gsm_log('secondary …4321', 'disabled')), 'pre-start state accepted')
			elseif options.late_gsm_enable then
				state.gsm(gsm_log('secondary …4321', 'enabling'))
			end
			state.gsm = observe
		end,
		wait_for = function(_, label, deadline, check)
			if label == 'disabled observation window' then
				assert(not check(), 'observation returned before its requested duration')
				state.now = deadline - 1
				assert(not check(), 'observation returned early')
				if options.transient_enable then
					local observe = state.watch['18'].observe
					observe({ kind = 'transition', from = 'disabled', state = 'enabling' })
					observe({ kind = 'transition', from = 'enabling', state = 'disabled' })
				elseif options.return_to_disabled then
					state.watch['18'].observe({ kind = 'transition', from = 'enabling', state = 'disabled' })
				elseif options.monitor_ended then
					state.watch['18'].ended = true
				elseif options.removed then
					state.watch['18'].observe({ kind = 'removed', state = 'absent' })
				elseif options.gsm_removed then
					state.gsm('daemon.info sh[42]: 2026-11-20 11:00:00 (mono=17.125)  LOG  gsm  info  '
						.. 'modem_removed  imei_suffix=4321 device=slot-2')
					state.gsm(gsm_log('secondary …4321', 'disabled'))
				elseif options.daemon_before_watch then
					state.gsm('daemon.info [4337]: <info>  [modem18] state changed (disabled -> enabling)')
				end
				state.now = deadline
				if options.final_state then fresh[secondary].state = options.final_state end
				if options.restarted then state.pid = '43' end
			end
			return assert(check(), label)
		end,
		diagnostics = function() state.diagnosed = true end,
	}
	instance.modems = {
		inventory = function(_, strict)
			assert(strict)
			state.inventory_reads = state.inventory_reads + 1
			return state.reset and fresh or prior
		end,
		clean_boot = function(_, targets)
			assert(state.written and not state.pid and targets[primary] and targets[secondary])
			state.reset = true
			return fresh, { [primary] = '7', [secondary] = '8' }
		end,
		watch_state = function(_, id, duration, observe)
			assert(state.reset and not state.pid and duration > box.args.timeout + box.args.observe_seconds)
			local watch = {
				observe = observe,
				wait_for = function(_, label, _, check) assert(check(), label) end,
				assert_open = function(self) assert(not self.ended, 'watch ended') end,
				finish = function(self)
					self:assert_open()
					if options.transition_in_drain and id == '18' then
						observe({ kind = 'transition', from = 'disabled', state = 'enabling' })
					end
					self.closed = true
				end,
			}
			state.watch[id] = watch
			if not (options.no_initial and id == '18') then observe({ kind = 'initial', state = 'disabled' }) end
			return watch
		end,
		diagnostic_commands = function() return {} end,
	}
	instance.runtime = {
		original = original(), prepare = function() end, ensure_dependencies = function() end,
		service_pids = function() return state.pid and { [state.pid] = true } or {} end,
		backup = function() state.backed_up = true end,
		build = function(_, _, config)
			assert(state.backed_up and config.gsm.data.modems.default.autoconnect == false)
			return 'build.tar.gz'
		end,
		deploy = function(self) self.changed, state.pid = true, nil end,
		write_config = function(_, config)
			assert(not state.pid and config.gsm.data.modems.known[1].autoconnect == false
				and config.gsm.data.modems.known[2].autoconnect == false)
			state.written = true
		end,
		service = function(_, action)
			assert(action == 'start' and not state.pid)
			if state.restored then state.pid = '44'; return end
			state.pid = '42'
			state.started = true
			state.gsm(gsm_log('primary …3456', 'disabled'))
			if options.early_respawn then state.pid = '43' end
			if not options.missing_second_gsm then
				state.gsm(gsm_log('secondary …4321', 'disabled', state.pid))
			end
			if options.early_respawn_after_gsm then state.pid = '43' end
		end,
		restore_runtime = function() state.restored, state.pid = true, nil end,
		diagnostic_commands = function() return {} end,
	}
	local ok, result = pcall(function()
		state.code = instance:run()
		state.results = util.decode(util.read(directory .. '/results.json'))
		return state
	end)
	os.remove(directory .. '/results.json')
	assert(unistd.rmdir(directory))
	assert(ok, result)
	return result
end

function tests.observes_both_fresh_modem_objects_and_restores_prior_service_state()
	local state = run({})
	assert(state.code == 0 and state.restored and state.pid == '44', state.err)
	assert(state.watch['17'].closed and state.watch['18'].closed and state.inventory_reads == 3)
	assert(state.results.observation_s == 60)
	for index, imei in ipairs({ primary, secondary }) do
		local result = state.results.modems[imei]
		assert(result.old_object_id == tostring(6 + index) and result.object_id == tostring(16 + index))
		assert(result.confirmed_state == 'disabled' and #result.gsm_events == 1 and #result.modemmanager_events == 1)
	end
	state = run({ stopped = true })
	assert(state.code == 0 and state.restored and not state.pid, state.err)
end

function tests.requires_fresh_independent_baselines_for_both_modems()
	local outcomes = {
		stale_object = 'pre-reset ModemManager object', no_initial = 'initial disabled state for secondary',
		missing_second_gsm = 'GSM disabled state for every selected modem',
	}
	for option, err in pairs(outcomes) do
		local state = run({ [option] = true })
		assert(state.code == 1 and state.diagnosed and state.restored and state.pid == '44')
		assert(state.err:find(err, 1, true), state.err)
		assert(not state.started or option == 'missing_second_gsm')
	end
end

function tests.detects_transient_or_unobserved_departures_from_disabled()
	local outcomes = {
		transient_enable = 'ModemManager reported enabling for secondary',
		return_to_disabled = 'ModemManager reported enabling for secondary',
		monitor_ended = 'watch ended', removed = 'ModemManager reported absent for secondary',
		gsm_removed = 'GSM reported absent for secondary',
		daemon_before_watch = 'ModemManager syslog reported enabling for secondary',
		transition_in_drain = 'ModemManager reported enabling for secondary',
		late_gsm_enable = 'GSM reported enabling for secondary',
		restarted = 'Devicecode stopped or restarted during observation',
		early_respawn = 'Devicecode log producer changed after startup',
		early_respawn_after_gsm = 'GSM baseline was produced by a different Devicecode process',
	}
	for option, err in pairs(outcomes) do
		local state = run({ [option] = true })
		assert(state.code == 1 and state.diagnosed and state.restored)
		assert(state.err:find(err, 1, true), state.err)
		assert(not state.results.modems[secondary].confirmed_state)
	end
	local state = run({ final_state = 'registered' })
	assert(state.code == 1 and state.err:find('state registered', 1, true), state.err)
end

for _, name in ipairs(util.keys(tests)) do tests[name]() end
print('PASS: modem autoconnect-off runner checks')
