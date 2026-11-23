#!/usr/bin/env luajit
local stdlib = require 'posix.stdlib'
local unistd = require 'posix.unistd'
local path = assert(stdlib.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/modem_reset$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path

local runner = require 'onbox.modem_reset.runner'
local util = require 'onbox.support.util'

local imei, port = '123456', '1-1.2'
local secondary, secondary_port = '213456', '1-1.4'
local address = '/org/freedesktop/ModemManager1/Modem/'
local tests = {}

local function log(source, state, id, device)
	return 'daemon.info sh[42]: 2026-11-20 11:00:00 (mono=100.000) (event_mono=17.125)  LOG  ' .. source
		.. '  info  modem_' .. state .. '  imei_suffix=3456 device=' .. (device or port)
		.. (id and ' address=' .. address .. id or '')
end

local function modem(id, device, state)
	return { id = id, device = '/sys/devices/usb1/' .. (device or port), state = state or 'connected' }
end

local function timed_log(service, what, summary, mono)
	return ('daemon.info sh[42]: 2026-11-20 11:00:00 (mono=100.000) (event_mono=%s) LOG %s info %s %s'):
		format(mono, service, what, summary)
end

local function net_online(role, device, mono)
	return timed_log('net', 'mwan_member_online', ('mwan member %s online interface=%s ifname=%s via=%s'):format(
		'member_' .. role, 'cell_' .. role, device, 'openwrt_' .. role), mono)
end

function tests.selects_every_modem_by_default_and_requires_both_to_be_ready()
	local inventory = { [imei] = modem('7'), [secondary] = modem('17', secondary_port) }
	local targets = runner.select_targets(inventory)
	assert(targets[imei].device == port and targets[secondary].device == secondary_port)
	targets = runner.select_targets(inventory, imei)
	assert(targets[imei].device == port and not targets[secondary])
	inventory[secondary].state = 'disabled'
	assert(not pcall(runner.select_targets, inventory))
	assert(not pcall(runner.select_targets, inventory, secondary))
	inventory[secondary].state = 'connected'
	inventory[secondary].device = inventory[imei].device
	assert(not pcall(runner.select_targets, inventory))
	assert(not pcall(runner.select_targets, inventory, imei))
	inventory[secondary] = nil
	assert(not pcall(runner.select_targets, inventory))
	assert(runner.select_targets(inventory, imei)[imei])
end

function tests.parser_matches_hal_and_gsm_lifecycle_for_the_same_imei_suffix_and_port()
	local target = runner.select_targets({ [imei] = modem('7') }, imei)[imei]
	local hal = assert(runner.parse_lifecycle(log('hal', 'removed', '7'), target))
	assert(hal.source == 'hal' and hal.state == 'removed' and hal.object_id == '7')
	assert(hal.monotonic_s == 100 and hal.event_monotonic_s == 17.125)
	local gsm = assert(runner.parse_lifecycle(log('gsm', 'added'), target))
	assert(gsm.source == 'gsm' and gsm.state == 'added' and not gsm.object_id)
	assert(not runner.parse_lifecycle(log('gsm', 'added', nil, '1-1.4'), target))
	assert(not runner.parse_lifecycle(log('gsm', 'added'):gsub('3456', '5432'), target))
	assert(not runner.parse_lifecycle(log('hal', 'added'), target))
	assert(not runner.parse_lifecycle(log('gsm', 'detected'), target))
end

local function run(options)
	local directory = assert(stdlib.mkdtemp('/tmp/onbox-reset-XXXXXX'))
	local state = { resets = {}, waits = {}, starts = 0 }
	local inventory = { [imei] = modem('7'), [secondary] = modem('17', secondary_port) }
	inventory[imei].net_ports, inventory[secondary].net_ports = { 'wwan0' }, { 'wwan1' }
	local config = { gsm = { data = { modems = { default = { autoconnect = true }, known = {
		{ id_field = 'device', device = inventory[imei].device, name = 'primary' },
		{ id_field = 'device', device = inventory[secondary].device, name = 'secondary' },
	} } } }, net = { data = { wan = { members = {
		member_primary = { interface = 'cell_primary', source = { kind = 'gsm-uplink', id = 'primary' } },
		member_secondary = { interface = 'cell_secondary', source = { kind = 'gsm-uplink', id = 'secondary' } },
	} } } } }
	if not options.stopped then state.pid = '40' end
	local wanted = options.imei
	if not options.both and not wanted then wanted = imei end
	local box = { args = { timeout = 30, imei = wanted, measure_recovery = options.timed,
		phase = options.timed and 'modem-recovery' or nil, max_online_s = options.max_online_s }, artifacts = directory }
	local instance = runner.from_session(box)
	box.run = function(_, body, hooks)
		local ok, err = pcall(body)
		if not ok then
			state.err = tostring(err)
			hooks.diagnostics()
		end
		local restored, restore_err = pcall(hooks.restore)
		if not restored then state.restore_err = tostring(restore_err) end
		return ok and restored and 0 or 1
	end
	box.phase = function(_, _, body) body() end
	box.logs = {
		checkpoint = function(_, label, observer)
			if label:match('^BEGIN tested modem reset ') then
				state.armed = true
				if options.lost_baseline then state.observe(log('hal', 'removed', '7')) end
				if #state.resets == 1 and (options.first_lost_after_wait or options.first_replaced_after_wait) then
					state.observe(log('hal', 'removed', '8'))
					state.observe(log('gsm', 'removed'))
					if options.first_replaced_after_wait then
						inventory[imei].id = '9'
						state.observe(log('hal', 'added', '9'))
						state.observe(log('gsm', 'added'))
					end
				end
			end
			if label:match('^END tested modem reset ') and options.drops_at_end then
				state.observe(log('gsm', 'removed'))
			end
			if label:match('^END tested modem reset ') and options.restarted_at_end then state.pid = '43' end
			state.observe = observer
			if label:match('^END tested modem reset ') and options.drops_after_end then
				state.observe(log('gsm', 'removed'))
			end
		end,
		wait_for = function(_, description, _, check) return assert(check(), description) end,
		diagnostics = function() state.diagnosed = true end,
	}
	box.ssh = { run = function(_, command)
		if command == 'ubus call mwan3 status' then
			return { stdout = util.encode({ interfaces = { openwrt_primary = { status = 'online' },
				openwrt_secondary = { status = 'online' } } }) }
		end
		if command == 'ubus call network.interface dump' then
			return { stdout = util.encode({ interface = {
				{ interface = 'openwrt_primary', l3_device = options.wrong_timed_device and 'wwan9' or 'wwan0', up = true },
				{ interface = 'openwrt_secondary', l3_device = options.wrong_timed_device and 'wwan9' or 'wwan1', up = true },
			} }) }
		end
		local old_id = assert(command:match('^mmcli %-m (%d+) %-%-reset$'))
		assert((old_id == '7' or old_id == '17') and state.pid == '42' and state.armed and state.observe)
		local key, device = imei, port
		if old_id == '17' then key, device = secondary, secondary_port end
		if #state.resets > 0 then assert(inventory[imei].state == 'connected') end
		state.resets[#state.resets + 1] = key
		local target = inventory[key]
		state.observe(log('gsm', 'added', nil, device)) -- A duplicate detection cannot prove a removal.
		state.observe(log('hal', 'removed', options.wrong_removal and '5' or old_id, device))
		if not options.missed_gsm_removal then state.observe(log('gsm', 'removed', nil, device)) end
		if options.timed and not options.missing_link_loss then
			local role = key == imei and 'primary' or 'secondary'
			state.observe(timed_log('net', 'gsm_uplink_changed', 'cellular uplink ' .. role .. ' unavailable', '17.120'))
		end
		target.id = options.same_object and old_id or tostring(tonumber(old_id) + 1)
		target.state = 'registered'
		if options.gsm_added_too_early then state.observe(log('gsm', 'added', nil, device)) end
		state.observe(log('hal', 'added', target.id, device))
		if options.foreign_second_gsm and key == secondary then
			state.observe(log('gsm', 'removed', nil, port))
			state.observe(log('gsm', 'added', nil, port))
		elseif not options.gsm_start_failed and not options.gsm_added_too_early then
			state.observe(log('gsm', 'added', nil, options.wrong_port and secondary_port or device))
		end
		if options.extra_reset then
			state.observe(log('hal', 'removed', target.id, device))
			target.id = '9'
			state.observe(log('hal', 'added', target.id, device))
		end
		if options.wrong_inventory then target.id = '9' end
		if options.restarted then state.pid = '43' end
		if options.timed then
			local role = key == imei and 'primary' or 'secondary'
			local ifname = target.net_ports[1]
			state.observe(net_online(role, ifname, '17.130')) -- Too early to prove recovery.
			state.observe(timed_log('gsm', 'modem_state_changed', role .. ' …3456 modem state -> connected', '17.375'))
			target.state = 'connected'
			if not options.no_timed_online then
				state.observe(net_online(role, options.wrong_timed_device and 'wwan9' or ifname, '17.925'))
			end
		end
	end }
	instance.modems = {
		inventory = function(_, strict)
			assert(strict)
			return inventory
		end,
		wait = function(_, targets, expected)
			assert(expected == 'connected' and state.pid == '42')
			state.waits[#state.waits + 1] = util.keys(targets)
			assert(not options.first_does_not_reconnect or #state.resets == 0, 'first modem did not reconnect')
			for key in pairs(targets) do inventory[key].state = 'connected' end
		end,
		diagnostic_commands = function() return {} end,
	}
	instance.runtime = {
		original = config, prepare = function() end, ensure_dependencies = function() end,
		service_pids = function() return state.pid and { [state.pid] = true } or {} end,
		backup = function() state.backed_up = true end,
		build = function() assert(state.backed_up); return 'build.tar.gz' end,
		deploy = function(self) self.changed, state.pid = true, nil end,
		write_config = function(self, candidate) assert(self.original == candidate) end,
		service = function(_, action)
			assert(action == 'start' and not state.pid)
			if state.restored then
				if not options.restore_failed then state.pid = '44' end
				return
			end
			state.pid = '42'
			state.starts = state.starts + 1
			state.observe(log('hal', 'added', '7'))
			state.observe(log('gsm', 'added'))
			state.observe(log('hal', 'added', '17', secondary_port))
			if not options.missing_second_baseline then state.observe(log('gsm', 'added', nil, secondary_port)) end
			if options.timed then
				state.observe(net_online('primary', 'wwan0', '15.500'))
				state.observe(net_online('secondary', 'wwan1', '15.650'))
			end
		end,
		restore_runtime = function() state.restored, state.pid = true, nil end,
		diagnostic_commands = function() return {} end,
	}
	local ok, result = pcall(function()
		instance.now = function()
			state.time = (state.time or 0) + 30
			return state.time
		end
		state.code = instance:run()
		state.results = util.decode(util.read(directory .. '/results.json')).modems
		return state
	end)
	os.remove(directory .. '/results.json')
	assert(unistd.rmdir(directory))
	assert(ok, result)
	return result
end

function tests.resets_after_the_baseline_and_records_both_lifecycles()
	local state = run({})
	assert(state.code == 0 and state.resets[1] == imei and state.restored and state.pid == '44', state.err)
	local result = state.results[imei]
	assert(result.before_object_id == '7' and result.after_object_id == '8')
	assert(#result.events == 5 and result.events[2].source == 'hal'
		and result.events[3].source == 'gsm' and result.events[3].state == 'removed')
	state = run({ stopped = true })
	assert(state.code == 0 and state.restored and not state.pid, state.err)
end

function tests.resets_both_modems_sequentially_under_one_devicecode_process()
	local state = run({ both = true })
	assert(state.code == 0 and state.starts == 1 and state.restored, state.err)
	assert(#state.resets == 2 and state.resets[1] == imei and state.resets[2] == secondary)
	assert(#state.waits == 2 and #state.waits[1] == 2 and #state.waits[2] == 1 and state.waits[2][1] == imei)
	assert(state.results[imei].before_object_id == '7' and state.results[imei].after_object_id == '8')
	assert(state.results[secondary].before_object_id == '17' and state.results[secondary].after_object_id == '18')
	assert(#state.results[imei].events == 5 and #state.results[secondary].events == 5)
	state = run({ imei = secondary })
	assert(state.code == 0 and #state.resets == 1 and state.resets[1] == secondary, state.err)
	assert(not state.results[imei] and state.results[secondary].after_object_id == '18')
end

function tests.measures_both_modems_using_box_timestamps_and_verified_interfaces()
	local state = run({ both = true, timed = true })
	assert(state.code == 0 and #state.resets == 2 and state.restored, state.err)
	for _, id in ipairs({ imei, secondary }) do
		local rec = state.results[id].recovery
		assert(rec.reappearance_to_connected_ms == 250 and rec.connected_to_online_ms == 550
			and rec.reappearance_to_online_ms == 800)
	end
	local failures = { { no_timed_online = true }, { missing_link_loss = true }, { wrong_timed_device = true },
		{ max_online_s = 0.799999 } }
	local messages = { 'GSM connected and NET online', 'GSM connected and NET online',
		'NET online device does not belong', '--max-online-seconds' }
	for index, options in ipairs(failures) do
		options.timed = true
		state = run(options)
		assert(state.code == 1 and state.restored and state.err:find(messages[index], 1, true), state.err)
	end
	state = run({ both = true, timed = true, max_online_s = 0.79 })
	assert(state.code == 1 and #state.resets == 2 and state.restored)
	assert(state.results[imei].recovery.online_limit_met == false
		and state.results[secondary].recovery.online_limit_met == false)
end
function tests.another_modems_events_cannot_satisfy_the_second_reset()
	local state = run({ both = true, foreign_second_gsm = true })
	assert(state.code == 1 and #state.resets == 2 and state.restored)
	assert(state.err:find('removal and reappearance in HAL and GSM', 1, true), state.err)
	assert(state.results[imei].after_object_id == '8')
	assert(state.results[secondary].before_object_id == '17' and not state.results[secondary].after_object_id)
end

function tests.stops_when_a_modem_is_not_ready()
	local state = run({ both = true, missing_second_baseline = true })
	assert(state.code == 1 and #state.resets == 0 and state.restored)
	assert(state.err:find('HAL and GSM baseline for all selected modems', 1, true), state.err)
	state = run({ both = true, first_does_not_reconnect = true })
	assert(state.code == 1 and #state.resets == 1 and state.restored)
	assert(state.err:find('first modem did not reconnect', 1, true), state.err)
	assert(state.results[imei].after_object_id == '8' and not state.results[secondary].before_object_id)
end

function tests.rechecks_the_recovered_modem_before_resetting_the_next()
	for _, option in ipairs({ 'first_lost_after_wait', 'first_replaced_after_wait' }) do
		local state = run({ both = true, [option] = true })
		assert(state.code == 1 and #state.resets == 1 and state.restored)
		assert(state.err:find('lost its verified connection before reset of', 1, true), state.err)
		assert(state.results[imei].after_object_id == '8' and not state.results[secondary].before_object_id)
	end
end

function tests.scores_only_lifecycle_events_inside_a_modems_reset_markers()
	local state = run({ drops_after_end = true })
	assert(state.code == 0 and state.results[imei].after_object_id == '8', state.err)
	assert(#state.results[imei].events == 5)
end

function tests.rejects_incomplete_or_wrong_modem_lifecycles()
	local failures = { 'wrong_removal', 'missed_gsm_removal', 'same_object', 'wrong_port', 'gsm_start_failed',
		'gsm_added_too_early' }
	for _, option in ipairs(failures) do
		local state = run({ [option] = true })
		assert(state.code == 1 and state.diagnosed and state.restored and state.pid == '44')
		assert(state.err:find('removal and reappearance in HAL and GSM', 1, true), state.err)
		assert(not state.results[imei].after_object_id)
	end
end

function tests.never_resets_after_losing_the_baseline()
	local state = run({ lost_baseline = true })
	assert(state.code == 1 and #state.resets == 0 and state.restored)
	assert(state.err:find('no longer matches the connected HAL and GSM baseline', 1, true), state.err)
end

function tests.fails_when_the_original_service_does_not_restart()
	local state = run({ restore_failed = true })
	assert(state.code == 1 and state.restored and state.results[imei].after_object_id == '8')
	assert(state.restore_err:find('Original Devicecode service did not return to running', 1, true), state.restore_err)
end

function tests.rejects_unconfirmed_inventory_and_devicecode_restart()
	local expected_errors = {
		wrong_inventory = 'ModemManager did not confirm',
		restarted = 'Devicecode restarted or stopped',
		restarted_at_end = 'Devicecode restarted or stopped',
		drops_at_end = 'removed again before the final checkpoint',
		extra_reset = 'HAL reported another modem replacement',
	}
	for option, expected in pairs(expected_errors) do
		local state = run({ [option] = true })
		assert(state.code == 1 and state.diagnosed and state.restored and state.pid == '44')
		assert(state.err:find(expected, 1, true), state.err)
	end
end

for _, name in ipairs(util.keys(tests)) do tests[name]() end
print('PASS: modem reset runner checks')
