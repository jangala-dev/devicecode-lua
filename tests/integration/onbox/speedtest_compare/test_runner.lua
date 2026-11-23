#!/usr/bin/env luajit
local stdlib = require 'posix.stdlib'
local stat = require 'posix.sys.stat'
local unistd = require 'posix.unistd'
local path = assert(stdlib.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/speedtest_compare$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path

local runner = require 'onbox.speedtest_compare.runner'
local cli = require 'onbox.speedtest_compare.cli'
local net = require 'onbox.support.net'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'

local function config()
	return { net = { rev = 7, data = { wan = { runtime = { speedtest = { scope = 'active', retry_after_s = 10 } },
		members = { wan = { interface = 'wan' }, modem_primary = {}, modem_secondary = {},
			secondary_alias = { interface = 'modem_secondary', metric = 2 }, held = { enabled = false } },
	} } } }
end

local function log(what, summary, pid)
	return ('daemon.info sh[%s]: 2026-11-20 11:00:00 (mono=17.125) LOG net info %s %s'):format(pid or '42', what, summary)
end

local function checked_comparisons()
	local original = config()
	local patched = runner.phase_config(original)
	local active = patched.net.data.wan.load_balancing.speedtests
	assert(active.scope == 'all' and active.enabled and not active.live_weights and active.retry_after_s == 10)
	assert(original.net.rev == 7 and original.net.data.wan.runtime.speedtest.scope == 'active')
	assert(patched.net.rev == 8 and not patched.net.data.wan.runtime.speedtest)
	local paths = runner.paths(patched)
	assert(paths.modem_primary.alias == nil and paths.modem_secondary.alias == nil)
	assert(paths.modem_secondary.member == 'modem_secondary' and not paths.held.enabled)
	local sample = assert(net.speedtest_event(log('speedtest_completed',
		'speedtest modem_secondary on modem_secondary/wwan1: 1.123456 Mbps (lower bound) source=10.0.0.2 via=mosec892')))
	assert(sample.mbps == 1.123456 and sample.lower_bound and sample.monotonic_s == 17.125)
	assert(sample.address == '10.0.0.2' and sample.alias == 'mosec892')
	assert(net.speedtest_event(log('speedtest_completed', 'speedtest wan failed: http_failed')).error == 'http_failed')
	local external = runner.external_result('mwan3 banner\n[{"download":18,"server":{"id":"9"}}]\nONBOX_LIBRESPEED_OK\n')
	assert(external.mbps == 18 and external.server.id == '9')
	external = runner.external_result('[{"download":18,"server":{"name":"test]"}}]\nONBOX_LIBRESPEED_OK\n')
	assert(external.server.name == 'test]')
	local diff = runner.compare(20, external.mbps)
	assert(diff.signed_mbps == -2 and diff.absolute_mbps == 2 and diff.percent == -10)
	assert(not pcall(runner.external_result, '[{"download":1}]'))
	assert(not pcall(runner.external_result, '[{"download":0}]\nONBOX_LIBRESPEED_OK\n'))
	assert(not pcall(runner.external_result, '[{"download":1},{"download":2}]\nONBOX_LIBRESPEED_OK\n'))
	local ok, err = pcall(runner.external_result, 'mwan3 banner\n', 'Error fetching server list: no route to host\n', 0)
	assert(not ok and err:find('no route to host', 1, true), err)
	local new_mwan_stderr = "could not find family for wan. Using ipv4.\n"
		.. "Running 'luajit ./speedtest-deadline.lua' with DEVICE=vl-wan SRCIP=192.0.2.10 FWMARK=0x3f00 FAMILY=ipv4\n"
		.. 'Error fetching server list: no route to host\nTerminated due to error\n'
	ok, err = pcall(runner.external_result, '', new_mwan_stderr, 1)
	assert(not ok and err:find('no route to host', 1, true), err)
	ok, err = pcall(runner.external_result, 'mwan3 banner\nnull\nONBOX_LIBRESPEED_OK\n', '', 0)
	assert(not ok and err:find('did not produce a measurement', 1, true), err)
	assert(not pcall(runner.external_command, '/tmp', { alias = 'bad; name', device = 'wwan1', address = '1.2.3.4' }))
end

local function checked_wrapper_binding()
	local directory = assert(stdlib.mkdtemp('/tmp/onbox-speedtest-binding-XXXXXX'))
	local quote = process.quote
	local ok, err = pcall(function()
		util.write(directory .. '/ip', '#!/bin/sh\nprintf "    inet 192.0.2.10/24\\n"\n')
		util.write(directory .. '/librespeed-cli', '#!/bin/sh\nprintf "CLI argv: %s\\n" "$*"\n')
		assert(stat.chmod(directory .. '/ip', 448))
		assert(stat.chmod(directory .. '/librespeed-cli', 448))
		local function invoke(mark)
			local output = assert(io.popen('cd ' .. quote(directory) .. ' && PATH=.:"$PATH" DEVICE=vl-wan'
				.. ' SRCIP=192.0.2.10 FWMARK=' .. quote(mark) .. ' luajit ' .. quote(here .. '/bounded_exec.lua')
				.. ' 3 vl-wan 192.0.2.10 --ipv4 2>&1'))
			local lines = output:read('*a')
			output:close()
			return lines
		end
		local valid = invoke('0x3f00')
		assert(valid:find('CLI argv: --interface vl-wan --fwmark 16128 --ipv4', 1, true), valid)
		assert(valid:find('ONBOX_LIBRESPEED_OK', 1, true), valid)
		for _, mark in ipairs({ '', '0x0', '0x100000000', '0x3f00 extra' }) do
			local invalid = invoke(mark)
			assert(invalid:find('Invalid mwan3 firewall mark', 1, true), invalid)
			assert(not invalid:find('CLI argv:', 1, true), invalid)
		end
	end)
	os.remove(directory .. '/ip')
	os.remove(directory .. '/librespeed-cli')
	assert(unistd.rmdir(directory))
	assert(ok, err)
end

local function checked_install(checksum)
	local remote, uploads = '/tmp/devicecode-speedtest-fixture', {}
	local box = { args = { here = here }, artifacts = '/local/artifacts', remote = remote }
	box.ssh = {
		run = function(_, command)
			if command == 'uname -m' then return { stdout = 'aarch64\n' } end
			assert(command:find('tmpfs', 1, true) or command:find(remote .. '/librespeed-cli', 1, true))
		end,
		upload = function(_, _, destination) uploads[#uploads + 1] = destination end,
	}
	box.process = { run = function(_, command)
		if command:match('^curl ') then
			assert(command:find('speedtest-cli-rust/releases/download/v1.2.1/librespeed-cli-aarch64-unknown-linux-musl.tar.gz',
				1, true))
		elseif command:match('^tar ') then
			assert(command:find('librespeed-cli-aarch64-unknown-linux-musl/librespeed-cli', 1, true))
		end
		return { code = 0, stdout = checksum .. '  archive\n', stderr = '' }
	end }
	return pcall(cli.install, box), uploads
end

local function run(options)
	local directory = assert(stdlib.mkdtemp('/tmp/onbox-speedtest-XXXXXX'))
	local state = { pid = '40', now = 0, commands = {} }
	local rollback_line = 'daemon.info sh[42]: 2026-11-20 11:00:00 (mono=17.2) LOG hal warn uci_rollback_done '
		.. 'uci_rollback_done ok=false err=network: uci: Parse error'
	local original = config()
	local box = { args = { timeout = 30, settle_s = 60, here = here, server_id = '9', runtime = '/runtime', repo = repo,
		service = '/etc/init.d/devicecode' },
		artifacts = directory,
		remote = '/tmp/speedtest-comparison' }
	box.process = { run = function(_, command)
		assert(command:find(repo .. '/build', 1, true))
		return { code = 0, stdout = '4000 build\n' }
	end }
	local instance = runner.from_session(box)
	local service = instance.runtime.service
	instance.now = function() return state.now end
	box.phase = function(_, _, body) body() end
	box.run = function(_, body, hooks)
		local ok, err = pcall(body)
		if not ok then state.err = tostring(err); hooks.diagnostics() end
		hooks.restore()
		return ok and 0 or 1
	end
	box.logs = {
		checkpoint = function(_, _, observer)
			if observer then assert(not observer(log('speedtest_completed', 'speedtest wan on wan/vl-wan: 999.0 Mbps'))) end
			state.observe = observer
		end,
		wait_for = function(_, label, deadline, check)
			if not check() then state.now = deadline end
			assert(check(), label)
		end,
		diagnostics = function() state.diagnosed = true end,
	}
	local devices = { modem_primary = 'wwan0', modem_secondary = 'wwan1', wan = 'vl-wan' }
	local aliases = { modem_primary = 'realpri', modem_secondary = 'realsec', wan = 'wan' }
	local addresses = { modem_primary = '10.0.0.1', modem_secondary = '10.0.0.2', wan = '10.0.0.3' }
	local online = { modem_primary = true, modem_secondary = not options.offline_secondary, wan = true }
	box.ssh = {
		run = function(_, command)
			if command == "'/etc/init.d/devicecode' stop" then
				if options.rollback_during_stop and state.observe then state.observe(rollback_line) end
				if options.stop_delay then
					state.stop_at = state.now + options.stop_delay
				else
					state.pid = nil
				end
				return { stdout = '' }
			end
			if command:match('^uci show network') then
				assert(not options.invalid_uci, 'UCI parse error')
				return { stdout = '' }
			end
			if command:match('^df %-Pk') then
				local available = options.full_overlay and 0 or options.no_rollback_reserve and 10000 or 16000
				return { stdout = tostring(available) .. '\n8000\n' }
			end
			assert(state.installed and not state.pid)
			local alias, device, ip = command:match('mwan3 use (%S+) luajit ./speedtest%-deadline.lua 90 (%S+) (%S+)')
			local interface
			for key, actual_alias in pairs(aliases) do if alias == actual_alias then interface = key end end
			assert(interface and online[interface] and device == devices[interface] and ip == addresses[interface])
			assert(command:find('--json --ipv4', 1, true) and command:find('--server 9', 1, true))
			state.commands[#state.commands + 1] = interface
			if options.failed_wan and interface == 'wan' then
				return { code = 0, stdout = 'mwan3 banner\n', stderr = 'Error fetching server list: no route to host\n' }
			end
			if options.goes_offline and interface == 'modem_primary' then online[interface] = false end
			return { code = 0, stdout = '[{"download":30,"server":{"id":"9"}}]\nONBOX_LIBRESPEED_OK\n', stderr = '' }
		end,
	}
	instance.install_cli = function()
		assert(not state.observe)
		state.installed = true
	end
	instance.snapshot = function()
		local mwan, netifd = {}, {}
		for id, alias in pairs(aliases) do
			if online[id] ~= nil then
				mwan[alias] = { status = online[id] and 'online' or 'offline' }
				netifd[alias] = { up = true, l3_device = devices[id],
					['ipv4-address'] = { { address = addresses[id] } } }
			end
		end
		return mwan, netifd
	end
	instance.runtime = {
		original = original, args = box.args, box = box, diagnostic_commands = function() return {} end,
		prepare = function(_, check_only) assert(check_only) end,
		service_pids = function() return state.pid and { [state.pid] = true } or {} end,
		backup = function() state.backup = true end,
		build = function() assert(state.backup); return 'check.tar.gz' end,
		deploy = function(self) self.changed, state.pid = true, nil end,
		write_config = function(_, patched) assert(patched.net.data.wan.load_balancing.speedtests.enabled) end,
		service = function(self, action)
			if action == 'stop' then return service(self, action) end
			if state.restored then state.pid = '44'; return end
			state.pid = '42'
			if options.apply_timeout then
				state.observe(log('apply_failed', 'network apply 3 failed: timeout'))
			else
				state.observe(log('apply_completed', 'network apply 1 completed in 2.1s'))
			end
			if options.rollback_failure then state.observe(rollback_line) end
			for id, up in pairs(online) do
				local status = up and 'online' or 'offline'
				local alias = options.no_primary_alias and id == 'modem_primary' and '?' or aliases[id]
				state.observe(log('mwan_member_' .. status, ('mwan member %s %s interface=%s ifname=%s via=%s'):format(
					id, status, id, devices[id], alias)))
				if up and not options.no_samples and (not options.missing_primary or id ~= 'modem_primary') then
					local ip = options.stale_primary_source and id == 'modem_primary' and '10.0.9.1' or addresses[id]
					state.observe(log('speedtest_completed', ('speedtest %s on %s/%s: 20.000000 Mbps source=%s via=%s'):
						format(id, id, devices[id], ip, alias)))
				end
			end
		end,
		restore_runtime = function() state.restored, state.pid = true, nil end,
	}
	local now, pause = process.now, process.pause
	process.now = instance.now
	process.pause = function(seconds)
		assert(state.stop_at and seconds > 0)
		state.now = state.now + seconds
		if state.now >= state.stop_at then
			if options.rollback_before_exit then state.observe(rollback_line) end
			state.pid, state.stop_at = nil, nil
		end
	end
	local ok, result = pcall(function()
		state.code = instance:run()
		if instance.paths then
			local results = util.decode(util.read(directory .. '/results.json'))
			state.results, state.apply_failure = results.interfaces, results.net_apply_failure
		end
		return state
	end)
	process.now, process.pause = now, pause
	os.remove(directory .. '/results.json')
	for index = 1, 4 do
		os.remove(directory .. '/speedtest-cli-' .. index .. '.stdout')
		os.remove(directory .. '/speedtest-cli-' .. index .. '.stderr')
	end
	assert(unistd.rmdir(directory))
	assert(ok, result)
	return result
end

checked_comparisons()
checked_wrapper_binding()
local installed, uploads = checked_install('1f15cd8a0d96c8383b7fde26bb36f24747f4473ee03cdcf3e32d814719e309a0')
assert(installed and #uploads == 2 and uploads[1]:match('^/tmp/.+/librespeed%-cli$'))
installed, uploads = checked_install('bad_checksum')
assert(not installed and #uploads == 0)
local state = run({})
assert(state.code == 0 and state.restored and state.pid == '44', state.err)
assert(table.concat(state.commands, ',') == 'modem_primary,modem_secondary,wan')
assert(state.results.modem_secondary.difference.percent == 50)
state = run({ failed_wan = true })
assert(state.code == 1 and state.restored)
assert(state.results.modem_primary.external and state.results.modem_secondary.external)
assert(state.err:find('wan: ', 1, true) and state.err:find('no route to host', 1, true), state.err)
assert(state.results.wan.cli_stderr_artifact == 'speedtest-cli-4.stderr' and not state.results.wan.external)
state = run({ stop_delay = 1 })
assert(state.code == 0 and state.restored and state.now == 1, state.err)
assert(table.concat(state.commands, ',') == 'modem_primary,modem_secondary,wan')
state = run({ stop_delay = math.huge })
assert(state.code == 1 and state.restored and not state.installed and #state.commands == 0)
assert(state.now == 45 and state.err:find('Devicecode is still running after stop (PIDs: 42)', 1, true), state.err)
state = run({ stop_delay = 1, rollback_before_exit = true })
assert(state.code == 1 and state.restored and not state.installed and #state.commands == 0)
assert(state.err:find('OpenWrt UCI rollback failed', 1, true), state.err)
state = run({ apply_timeout = true })
assert(state.code == 0 and state.restored and state.pid == '44', state.err)
assert(table.concat(state.commands, ',') == 'modem_primary,modem_secondary,wan')
assert(state.apply_failure == 'network apply 3 failed: timeout')
local unsafe_boxes = { full_overlay = 'Insufficient free runtime storage', invalid_uci = 'UCI parse error' }
for option, expected in pairs(unsafe_boxes) do
	state = run({ [option] = true })
	assert(state.code == 1 and state.pid == '40' and not state.backup and not state.installed)
	assert(state.err:find(expected, 1, true), state.err)
end
state = run({ no_rollback_reserve = true })
assert(state.code == 1 and state.backup and state.pid == '40' and not state.restored and not state.installed)
assert(state.err:find('Insufficient free runtime storage for deployment and rollback', 1, true), state.err)
state = run({ apply_timeout = true, no_samples = true })
assert(state.code == 1 and state.restored and not state.installed and #state.commands == 0)
assert(state.apply_failure == 'network apply 3 failed: timeout')
state = run({ apply_timeout = true, rollback_failure = true })
assert(state.code == 1 and state.restored and not state.installed and #state.commands == 0)
assert(state.err:find('OpenWrt UCI rollback failed', 1, true), state.err)
state = run({ rollback_during_stop = true })
assert(state.code == 1 and state.restored and not state.installed and #state.commands == 0)
assert(state.err:find('OpenWrt UCI rollback failed', 1, true), state.err)
state = run({ offline_secondary = true, goes_offline = true })
assert(state.code == 0 and #state.commands == 2, state.err)
assert(state.results.modem_secondary.excluded == 'mwan3 offline' and not state.results.modem_secondary.external)
assert(state.results.modem_primary.excluded:find('during CLI test', 1, true))
state = run({ missing_primary = true })
assert(state.code == 1 and state.restored and state.diagnosed and #state.commands == 2)
assert(state.results.modem_primary.error:find('No successful fresh Devicecode speedtest', 1, true))
assert(state.results.modem_secondary.external and state.results.wan.external)
state = run({ stale_primary_source = true })
assert(state.code == 1 and #state.commands == 2 and not state.results.modem_primary.external)
assert(state.results.modem_primary.error:find('selected interface and source address', 1, true))
state = run({ no_primary_alias = true })
assert(state.code == 1 and #state.commands == 2 and not state.results.modem_primary.external)
assert(state.results.modem_primary.error:find('online without an OpenWrt interface', 1, true))
print('PASS: speedtest comparison runner checks')
