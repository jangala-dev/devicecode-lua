#!/usr/bin/env luajit
-- Offline checks: fake deployment, mmcli, service restarts and local UI responses.
local posix = require 'posix'
local stat = require 'posix.sys.stat'
local path = assert(posix.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/cellular_modes$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
local runner = require 'onbox.cellular_modes.runner'
local util = require 'onbox.support.util'
local modes = require 'services.hal.types.modem_modes'
local tablex = require 'shared.table'
local T = {}

local function pair(preferred, allowed)
	local result = assert(modes.normalize(preferred, allowed))
	return result
end

local function rejects(body)
	local ok = pcall(body)
	assert(not ok, 'Expected rejection')
end

local function raw(pair_value)
	return 'allowed: ' .. table.concat(pair_value.allowed, ', ') .. '; preferred: ' .. pair_value.preferred
end

function T.pair_must_be_advertised_and_differ_from_live_and_configured_modes()
	local original = pair('4g', { '2g', '3g', '4g' })
	local configured = pair('none', { '4g' })
	local alternate = pair('4g', { '3g', '4g' })
	local supported = { configured, alternate }
	assert(modes.equal(runner.choose_pair(original, supported, configured), alternate))
	assert(modes.equal(runner.choose_pair(original, supported, configured, alternate), alternate))
	rejects(function() runner.choose_pair(original, supported, configured, configured) end)
	rejects(function() runner.choose_pair(configured, supported, nil, configured) end)
	rejects(function() runner.choose_pair(original, { configured }, configured) end)
	rejects(function() runner.choose_pair(original, supported, nil, pair('none', { '5g' })) end)
	assert(modes.equal(runner.parse_pair(' allowed: 4g, 3g; preferred: 4g '), alternate))
	rejects(function() runner.parse_pair('allowed: 3g,,4g; preferred: 4g') end)
	rejects(function() runner.parse_pair('allowed: 3g; preferred: 4g') end)
end

function T.arguments_validate_before_opening_a_session()
	local args = runner.parse_args({ '--ssh-key-auth', '--imei', '123', '--preferred', '4g',
		'--allowed', '4g,3g,4g', '--ui-url', 'http://127.0.0.1:8080/' }, repo, here)
	assert(args.requested.preferred == '4g' and table.concat(args.requested.allowed, ',') == '3g,4g')
	assert(args.imei == '123' and args.ui_url == 'http://127.0.0.1:8080')
	rejects(function() runner.parse_args({ '--preferred', '4g' }, repo, here) end)
	rejects(function() runner.parse_args({ '--preferred', '4g', '--allowed', '3g' }, repo, here) end)
	rejects(function() runner.parse_args({ '--preferred', '4g', '--allowed', '3g,,4g' }, repo, here) end)
	rejects(function() runner.parse_args({ '--imei', 'bad; command' }, repo, here) end)
	rejects(function() runner.parse_args({ '--preferred', 'none', '--allowed', '2g' }, repo, here) end)
	rejects(function() runner.parse_args({ '--preferred', '4g', '--allowed', '2g,3g,4g' }, repo, here) end)
end

function T.automatic_pair_excludes_2g_and_prefers_4g_over_3g()
	local original = pair('4g', { '3g', '4g' })
	local supported = { pair('none', { '2g' }), pair('none', { '3g' }), original, pair('none', { '4g' }) }
	assert(modes.equal(runner.choose_pair(original, supported), supported[4]))
	assert(modes.equal(runner.choose_pair(supported[4], supported), original))
	rejects(function() runner.choose_pair(original, supported, nil, supported[1]) end)
end

function T.phase_config_prioritizes_imei_overrides_and_preserves_other_settings()
	local original = { gsm = { rev = 8, data = { modems = {
		default = { signal_freq = 10, cellular_modes = pair('none', { '3g', '4g' }) },
		known = { { id_field = 'device', device = '/dev/modem', name = 'primary', autoconnect = true },
			{ imei = 'other', name = 'secondary' } },
	} } } }
	local targets = { ['123'] = { info = { imei = '123', device = '/dev/modem' }, name = 'primary',
		requested = pair('none', { '4g' }) } }
	local config = runner.phase_config(original, targets, { ['123'] = targets['123'].requested }, 1)
	local first = config.gsm.data.modems.known[1]
	assert(config.gsm.rev == 9 and first.imei == '123' and first.id_field == 'imei' and first.device == nil)
	assert(first.name == 'primary' and first.autoconnect and first.signal_freq == 10)
	assert(modes.equal(first.cellular_modes, targets['123'].requested))
	assert(config.gsm.data.modems.known[3].imei == 'other')
	assert(#original.gsm.data.modems.known == 2 and original.gsm.rev == 8)
	assert(original.gsm.data.modems.known[1].cellular_modes == nil)
end

function T.effective_config_ignores_empty_device_paths()
	local config = { gsm = { data = { modems = { default = { name = 'default' },
		known = { { id_field = 'device', device = '', name = 'empty' } },
	} } } }
	assert(runner.effective_config(config, { imei = '123', device = '' }).name == 'default')
end

function T.ui_record_requires_matching_service_modem_requested_pair_and_event()
	local expected = pair('none', { '4g' })
	local target = { name = 'primary' }
	local record = { service = 'gsm', what = 'cellular_modes_applied',
		payload = { modem = 'primary', requested = expected } }
	local function matches(event) return runner.matches_record(record, target, expected, event) end
	assert(matches('cellular_modes_applied'))
	assert(not runner.matches_record({ service = 'net', payload = 1 }, target, expected, record.what))
	record.what, record.level = 'cellular_modes_unsupported', 'info'
	assert(not matches('cellular_modes_applied') and not matches('cellular_modes_unsupported'))
	record.level = 'warn'
	assert(matches('cellular_modes_unsupported'))
	record.payload.modem = 'secondary'
	assert(not matches('cellular_modes_unsupported'))
	record.payload.modem, record.payload.requested = 'primary', pair('4g', { '3g', '4g' })
	assert(not matches('cellular_modes_unsupported'))
end

local function remove_tree(directory)
	for name in posix.files(directory) do
		if name ~= '.' and name ~= '..' then
			local child = directory .. '/' .. name
			if stat.S_ISDIR(assert(stat.lstat(child)).st_mode) ~= 0 then remove_tree(child) else assert(os.remove(child)) end
		end
	end
	assert(posix.rmdir(directory))
end

local function fixture(body, options)
	options = options or {}
	local temp = assert(posix.mkdtemp('/tmp/onbox-cellular-XXXXXX'))
	local original = options.original or pair('4g', { '3g', '4g' })
	local supported = { pair('4g', { '3g', '4g' }), pair('none', { '4g' }) }
	local inventory = { ['123'] = { imei = '123', id = '1', device = '/dev/modem', state = 'registered' } }
	local starting, live = { ['123'] = original }, { ['123'] = original }
	local base = { gsm = { rev = 1, data = { modems = { default = { enabled = true },
		known = { { id_field = 'device', device = '/dev/modem', name = 'primary', autoconnect = true } },
	} } }, ui = { data = { enabled = true, http = { port = 80 } } } }
	base.gsm.data.modems.default.cellular_modes = options.configured_default
	base.gsm.data.modems.known[1].cellular_modes = options.configured_entry
	if options.secondary then
		inventory['456'] = { imei = '456', id = '2', device = '/dev/secondary', state = 'registered' }
		starting['456'], live['456'] = options.secondary, options.secondary
		table.insert(base.gsm.data.modems.known, { imei = '456', name = 'secondary' })
	end
	local state = { live = live, pid = 100, records = {}, builds = {}, deployments = 0,
		restarts = 0, queries = 0, time = 0, direct_sets = 0, diagnostics = 0, log_subscriptions = 0 }
	local box = { args = { service = '/etc/init.d/devicecode', timeout = 6 }, artifacts = temp }
	box.phase = function(_, _, callback) callback() end
	box.run = function(_, callback, hooks)
		local ok, err = pcall(callback)
		box.recovering = true
		if not ok then
			state.error = tostring(err)
			hooks.diagnostics()
			hooks.restore(true)
		else
			hooks.restore(false)
		end
		return ok and 0 or 1
	end
	box.logs = { diagnostics = function() state.diagnostics = state.diagnostics + 1 end }
	box.ssh = { run = function(_, command)
		if command:find('ubus call service list', 1, true) then
			return { code = 0, stdout = util.encode({ devicecode = { instances = {
				main = { pid = state.pid, running = state.pid ~= nil },
			} } }) }
		end
		local id = assert(command:match("mmcli %-m '(%d+)'"), command)
		local imei
		for _, info in pairs(inventory) do if info.id == id then imei = info.imei end end
		assert(imei, 'Unexpected modem ID')
		if command:find('--set-allowed-modes=', 1, true) then
			assert(not command:find('2g', 1, true), 'rollback must never reapply 2G')
			state.direct_sets = state.direct_sets + 1
			live[imei] = starting[imei]
			return { code = 0, stdout = '' }
		end
		state.queries = state.queries + 1
		local advertised = {}
		for _, candidate in ipairs(supported) do advertised[#advertised + 1] = raw(candidate) end
		return { code = 0, stdout = util.encode({ modem = { generic = {
			['equipment-identifier'] = imei, ['current-modes'] = raw(live[imei]),
			['supported-modes'] = advertised,
		} } }) }
	end }
	local instance = runner.from_session(box)
	instance.now = function() return state.time end
	instance.pause = function(seconds) state.time = state.time + seconds end
	instance.follow_logs = function(_, url, _, _, accept, complete, expected)
		assert(url == 'http://127.0.0.1:80')
		state.log_subscriptions = state.log_subscriptions + 1
		for _, record in ipairs(options.records or state.records) do accept(record) end
		return assert(complete(), 'Timed out waiting for ' .. expected)
	end
	instance.modems = { inventory = function() return inventory end,
		diagnostic_commands = function() return {} end }
	instance.runtime = { original = base,
		service_pids = function() return state.pid and { [tostring(state.pid)] = true } or {} end,
		prepare = function(self)
			if options.persistent then
				self.persistent_existed = true
				local config = tablex.deep_copy(base)
				config.gsm.data.modems.default.signal_freq = 17
				config.gsm.data.modems.default.cellular_modes = options.persistent.default
				config.gsm.data.modems.known[1].cellular_modes = options.persistent.entry
				util.write(temp .. '/original-persistent.json', util.encode(config))
			end
		end,
		ensure_dependencies = function(_, dependencies)
			assert(dependencies.commands.curl and dependencies.commands.mmcli and dependencies.commands.ubus)
		end,
		backup = function() state.backed_up = true end,
		build = function(_, label, config)
			assert(state.backed_up and next(live))
			state.builds[#state.builds + 1] = { label = label, config = tablex.deep_copy(config) }
			return label .. '.tar.gz'
		end,
		deploy = function(self, archive)
			assert(archive == state.builds[#state.builds].label .. '.tar.gz')
			state.deployments, self.changed, state.pid = state.deployments + 1, true, nil
		end,
		write_config = function(_, config) state.config = config end,
		service = function(_, action)
			if action == 'start' then
				assert(state.restored_runtime)
				state.started_original = true
				return
			end
			assert(action == 'restart')
			state.restarts = state.restarts + 1
			state.pid = options.stale_pid and 100 or 100 + state.restarts
			state.records = {}
			for index, imei in ipairs(util.keys(inventory)) do
				inventory[imei].id = tostring(state.restarts * 2 + index)
				local cfg = runner.effective_config(state.config, inventory[imei])
				local request = cfg.cellular_modes
				if request and not state.restored_runtime and not modes.equal(request, live[imei]) then
					assert(not modes.includes(request, '2g'), 'test deployed a 2G pair')
					local recognized = false
					for _, candidate in ipairs(supported) do recognized = recognized or modes.equal(request, candidate) end
					if recognized and not options.unchanged_modem then live[imei] = tablex.deep_copy(request) end
					if not recognized and options.changes_unsupported then live[imei] = pair('none', { '3g' }) end
					if not (recognized and options.missing_applied or not recognized and options.missing_warning) then
						state.records[#state.records + 1] = {
							service = 'gsm', level = recognized and 'info' or 'warn',
							what = recognized and 'cellular_modes_applied' or 'cellular_modes_unsupported',
							payload = { modem = cfg.name, requested = request },
						}
					end
				end
			end
		end,
		restore_runtime = function(self)
			state.restored_runtime, state.config, state.pid, self.changed = true, base, nil, false
		end,
		diagnostic_commands = function() return {} end,
	}
	local ok, err = pcall(body, instance, state, original)
	remove_tree(temp)
	assert(ok, err)
end

function T.full_scenario_checks_rejection_and_restores_the_original_pair()
	fixture(function(instance, state, original)
		assert(instance:run() == 0, state.error)
		assert(#state.builds == 3 and state.restarts == 3)
		assert(instance.summary[2].records['123'].what == 'cellular_modes_unsupported')
		assert(modes.equal(instance.summary[2].actual['123'], instance.summary[1].actual['123']))
		assert(instance.summary[3].records['123'].what == 'cellular_modes_applied')
		assert(modes.equal(state.live['123'], original))
	end)
end

function T.full_scenario_cleans_up_after_rejection_even_if_all_originals_are_unsafe()
	fixture(function(instance, state, original)
		assert(instance:run() == 0, state.error)
		assert(#state.builds == 3 and state.deployments == 3 and state.restarts == 3)
		assert(state.log_subscriptions == 2 and state.direct_sets == 0)
		assert(not modes.equal(state.live['123'], original) and modes.equal(state.live['123'], pair('none', { '4g' })))
		assert(instance.summary[3].restore_skipped['123'] == 'original modes allow 2G')
		assert(modes.equal(instance.summary[3].actual['123'], state.live['123']))
		assert(state.restored_runtime and state.started_original)
		assert(state.config.gsm.data.modems.known[1].cellular_modes == nil)
	end, { original = pair('4g', { '2g', '3g', '4g' }) })
end

function T.restores_only_eligible_modems_in_a_mixed_run()
	fixture(function(instance, state, original)
		assert(instance:run() == 0, state.error)
		local final = instance.summary[3]
		assert(final.records['123'].what == 'cellular_modes_applied' and final.records['456'] == nil)
		assert(final.restore_skipped['456'] == 'original modes were not advertised')
		assert(modes.equal(final.actual['123'], original))
		assert(modes.equal(final.actual['456'], instance.summary[1].actual['456']))
	end, { secondary = pair('none', { '3g', '4g' }) })
end

function T.rejection_requires_both_the_warning_and_unchanged_hardware()
	fixture(function(instance, state)
		assert(instance:run() == 1 and state.error:find('cellular_modes_unsupported', 1, true))
		assert(state.restored_runtime and #instance.summary == 1)
	end, { missing_warning = true })
	fixture(function(instance, state)
		assert(instance:run() == 1 and state.error:find('02-unsupported mmcli modes', 1, true))
		assert(state.restored_runtime and #instance.summary == 1)
	end, { changes_unsupported = true })
end

function T.persistent_mode_fields_are_inherited_when_selecting_a_different_pair()
	fixture(function(instance, state)
		assert(instance:run() == 0, state.error)
		local request = instance.targets['123'].requested
		assert(modes.equal(instance.targets['123'].configured, pair('4g', { '3g', '4g' })))
		assert(modes.equal(request, pair('none', { '4g' })))
		assert(state.builds[1].config.gsm.data.modems.default.signal_freq == 17)
	end, { persistent = { default = pair('4g', { '4g' }), entry = { allowed = { '3g', '4g' } } },
		original = pair('4g', { '2g', '3g', '4g' }) })
end

function T.config_that_would_request_2g_stops_before_deployment()
	fixture(function(instance, state)
		assert(instance:run() == 1 and state.error:find('explicitly configures 2G', 1, true))
		assert(not state.backed_up and state.deployments == 0 and state.restarts == 0 and state.direct_sets == 0)
	end, { configured_default = pair('4g', { '3g', '4g' }),
		configured_entry = { allowed = { '2g', '4g' } } })
end

function T.modem_records_are_collected_without_counting_duplicates()
	local function record(name)
		return { service = 'gsm', what = 'cellular_modes_applied',
			payload = { modem = name, requested = pair('none', { '4g' }) } }
	end
	fixture(function(instance)
		instance.ui_url = 'http://127.0.0.1:80'
		local requested = {}
		for _, name in ipairs({ '123', '456', '789' }) do
			instance.targets[name] = { name = name }
			requested[name] = pair('none', { '4g' })
		end
		local records = instance:wait_logs('split', requested, 'cellular_modes_applied')
		for _, name in ipairs({ '123', '456', '789' }) do assert(records[name].payload.modem == name) end
	end, { records = { record('123'), record('123'), record('456'), record('789') } })
end

function T.missing_application_log_restores_runtime_and_a_safe_original_pair()
	fixture(function(instance, state, original)
		assert(instance:run() == 1)
		assert(state.error:find('cellular_modes_applied', 1, true))
		assert(#state.builds == 1 and state.restored_runtime and state.diagnostics == 1)
		assert(state.direct_sets == 1 and modes.equal(state.live['123'], original))
	end, { missing_applied = true })
end

function T.rollback_does_not_reapply_a_live_2g_baseline()
	fixture(function(instance, state)
		assert(instance:run() == 1 and state.restored_runtime)
		assert(state.direct_sets == 0 and modes.equal(state.live['123'], pair('none', { '4g' })))
	end, { missing_applied = true, original = pair('4g', { '2g', '3g', '4g' }) })
end

function T.application_log_without_hardware_change_fails()
	fixture(function(instance, state)
		assert(instance:run() == 1)
		assert(state.error:find('01-valid mmcli modes', 1, true))
		assert(state.restored_runtime and #instance.summary == 0 and state.direct_sets == 0)
	end, { unchanged_modem = true })
end

function T.restart_must_replace_the_old_process_before_api_or_mode_checks()
	fixture(function(instance, state, original)
		assert(instance:run() == 1)
		assert(state.error:find('fresh service process', 1, true))
		assert(#instance.summary == 0 and state.restored_runtime and modes.equal(state.live['123'], original))
	end, { stale_pid = true })
end

local names = util.keys(T)
for _, name in ipairs(names) do T[name](); print('PASS ' .. name) end
print(('%d cellular generation on-box runner tests passed'):format(#names))
