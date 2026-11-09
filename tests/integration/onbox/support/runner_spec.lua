local bit = require 'bit'
local dirent = require 'posix.dirent'
local errno = require 'posix.errno'
local fcntl = require 'posix.fcntl'
local signals = require 'posix.signal'
local stat = require 'posix.sys.stat'
local stdlib = require 'posix.stdlib'
local unistd = require 'posix.unistd'
local wait = require 'posix.sys.wait'
local auth = require 'onbox.support.auth'
local runner = require 'onbox.support.runner'
local process = require 'onbox.support.process'
local fiber_runtime = require 'onbox.support.fiber_runtime'
local logs = require 'onbox.support.logs'
local devicecode = require 'onbox.support.devicecode'
local modem = require 'onbox.support.modem'
local util = require 'onbox.support.util'
local quote = process.quote

local tests = {}
local module_source = assert(debug.getinfo(1, 'S').source:match('^@(.+)$'))
local here = assert(stdlib.realpath(module_source)):match('^(.*)/[^/]+$')
local repo = assert(here:match('^(.*)/tests/integration/onbox/support$'))

---@param actual any
---@param expected any
---@return nil
local function equal(actual, expected)
	assert(actual == expected, ('Expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

---@param callback fun(): any
---@param message string
---@return nil
local function rejects(callback, message)
	local ok, err = pcall(callback)
	assert(not ok and tostring(err):find(message, 1, true), 'Expected failure containing: ' .. message)
end

---@param snapshots table<string, OnboxModemInfo>[]
---@param body fun(modems: OnboxModems, commands: string[]): nil
---@return nil
local function with_modem_inventory(snapshots, body)
	local commands, ticks, reads = {}, 0, 0
	local modems = modem.new({ args = { timeout = 10 }, ssh = { run = function(_, command)
		commands[#commands + 1] = command
	end } })
	modems.inventory = function()
		reads = reads + 1
		return snapshots[math.min(reads, #snapshots)]
	end
	local saved_now, saved_pause = process.now, process.pause
	process.now = function() return ticks end
	process.pause = function() ticks = ticks + 1 end
	local ok, err = pcall(body, modems, commands)
	process.now, process.pause = saved_now, saved_pause
	assert(ok, err)
end

---@param path string
---@return nil
local function remove_tree(path)
	local info = stat.stat(path)
	if not info then return end
	if stat.S_ISDIR(info.st_mode) ~= 0 then
		for name in dirent.files(path) do
			if name ~= '.' and name ~= '..' then remove_tree(path .. '/' .. name) end
		end
		assert(unistd.rmdir(path))
	else assert(os.remove(path)) end
end

---@param body fun(box: OnboxSession, temp: string): nil
---@return nil
local function with_session(body)
	local temp = assert(stdlib.mkdtemp('/tmp/onbox-support-XXXXXX'))
	local args = runner.parse_args({ '--ssh-key-auth', '--artifacts', temp .. "/space and ' quote" }, repo, here)
	local box = runner.new(args)
	box.remote = temp .. '/remote'
	local ok, err = pcall(body, box, temp)
	box.ssh:close()
	remove_tree(temp)
	assert(ok, err)
end

---@return nil
function tests.common_arguments_extend_without_test_specific_defaults()
	local args = runner.parse_args({}, repo, here)
	equal(args.password_file, repo .. '/boxkey')
	equal(args.ask_pass, false)
	equal(args.yes, false)
	equal(args.build_command, 'make build-all')
	equal(args.first, nil)
	equal(args.keep_final_config, nil)
	args = runner.parse_args({ '--custom', 'value', '--leave-config', '--ssh-key-auth' }, repo, here, {
		defaults = { custom = 'default' }, values = { ['--custom'] = 'custom' },
		flags = { ['--leave-config'] = 'leave_config' },
	})
	equal(args.custom, 'value')
	equal(args.leave_config, true)
	equal(args.password_file, nil)
	args = runner.parse_args({ '--yes' }, repo, here)
	equal(args.yes, true)
	rejects(function() runner.parse_args({ '--timeout', '0' }, repo, here) end, 'Timeout must be positive')
	rejects(function() runner.parse_args({ '--runtime', '/' }, repo, here) end, 'Runtime must name')
	rejects(function() runner.parse_args({ '--host' }, repo, here) end, 'Missing value')
	for _, flags in ipairs({ { '--ask-pass', '--ssh-key-auth' }, { '--ssh-key-auth', '--ask-pass' },
		{ '--ask-pass', '--password-file', 'unused' }, { '--password-file', 'unused', '--ask-pass' } }) do
		rejects(function() runner.parse_args(flags, repo, here) end, 'Choose one of')
	end
end

---@return nil
function tests.target_identity_is_logged_and_confirmation_can_be_skipped_or_required()
	with_session(function(box)
		box.ssh.run = function()
			return { code = 0, stderr = '', stdout = table.concat({
				'hostname=lab-box',
				'hardware_revision=bigbox-v1',
				'machine_id=0123456789abcdef',
				'serial=BB-42',
			}, '\n') .. '\n' }
		end
		box.process.run = function()
			return { code = 0, stderr = '', stdout = '256 SHA256:example-key box (ED25519)\n' }
		end
		local output = { content = '' }
		function output:write(value) self.content = self.content .. value end
		function output:flush() end

		box.args.yes = true
		local identity = box:confirm_target(nil, output)
		equal(identity.route, 'root@172.28.100.1')
		equal(identity.hostname, 'lab-box')
		equal(identity.ssh_host_key, 'SHA256:example-key')
		assert(output.content:find('machine ID: 0123456789abcdef', 1, true))
		assert(output.content:find('[y/N]', 1, true) == nil)
		equal(util.read(box.artifacts .. '/box-identity.log'), output.content)

		box.args.yes = false
		output.content = ''
		local reader = { read = function() return 'yes' end }
		box:confirm_target(reader, output)
		assert(output.content:find('[y/N]', 1, true))

		reader = { read = function() return 'no' end }
		rejects(function() box:confirm_target(reader, output) end, 'On-box test cancelled')
	end)
end

---@return nil
function tests.local_commands_preserve_stdin_stderr_exit_status_and_timeout()
	with_session(function(box)
		local result = box.process:run("printf 'hello'; printf 'error' >&2; exit 7")
		equal(result.stdout, 'hello')
		equal(result.stderr, 'error')
		equal(result.code, 7)
		local input_source = box.artifacts .. '/input'
		util.write(input_source, 'input data')
		result = box.process:run('cat', { input_path = input_source })
		equal(result.stdout, 'input data')
		equal(result.code, 0)
		equal(box.process:run('sleep 10', { timeout = 0.1 }).code, 124)
		box.interrupted = true
		rejects(function() box.process:run('true') end, 'Interrupted')
		box.recovering = true
		equal(box.process:run('true').code, 0)
		equal(bit.band(stat.stat(box.artifacts).st_mode, 511), 448)
	end)
end

---@return nil
function tests.fiber_process_launches_short_commands_and_preserves_terminal_status()
	with_session(function(box)
		for _ = 1, 20 do
			equal(box.process:run('true').code, 0)
			equal(box.process:run('exit 7').code, 7)
		end
		local stdout = assert(stat.stat(box.artifacts .. '/command.stdout'))
		local stderr = assert(stat.stat(box.artifacts .. '/command.stderr'))
		equal(bit.band(stdout.st_mode, 511), 384)
		equal(bit.band(stderr.st_mode, 511), 384)

		local input = box.artifacts .. '/large-input'
		util.write(input, string.rep('large early-exit input\n', 131072))
		for _ = 1, 5 do
			equal(box.process:run('exit 0', { input_path = input }).code, 0)
			equal(box.process:run('exit 7', { input_path = input }).code, 7)
		end
		equal(box.process:run('exec 0<&-; sleep 1', { input_path = input, timeout = 0.05 }).code, 124)
	end)
end

---@return nil
function tests.foreground_runs_serialize_without_blocking_background_start()
	with_session(function(box)
		local f = fiber_runtime.get()
		f.fibers.run(function()
			local first_started = box.artifacts .. '/first-started'
			local second_started = box.artifacts .. '/second-started'
			local release = box.artifacts .. '/release-first'
			local background_log = box.artifacts .. '/background.log'
			local first_done, second_done = f.oneshot.new(), f.oneshot.new()
			local first, second
			assert(f.fibers.spawn(function()
				first = box.process:run('touch ' .. quote(first_started)
					.. '; while test ! -e ' .. quote(release) .. '; do sleep 0.01; done; printf first')
				first_done:signal()
			end))
			local deadline = process.now() + 2
			while not stat.stat(first_started) and process.now() < deadline do f.sleep.sleep(0.01) end
			assert(stat.stat(first_started), 'First foreground command did not start')
			assert(f.fibers.spawn(function()
				second = box.process:run('touch ' .. quote(second_started) .. '; printf second', { timeout = 0.05 })
				second_done:signal()
			end))
			f.sleep.sleep(0.1)
			assert(not stat.stat(second_started), 'Queued foreground command launched before gate release')

			local background_pid = box.process:start('printf background; sleep 30', background_log)
			deadline = process.now() + 2
			while util.read(background_log) ~= 'background' and process.now() < deadline do f.sleep.sleep(0.01) end
			equal(util.read(background_log), 'background')

			util.write(release, '')
			f.fibers.perform(fiber_runtime.oneshot_op(first_done))
			f.fibers.perform(fiber_runtime.oneshot_op(second_done))
			equal(first.stdout, 'first')
			equal(second.stdout, 'second')
			equal(second.code, 0)
			box.process:stop(background_pid)

			equal(box.process:run('sleep 1', { timeout = 0.05 }).code, 124)
			equal(box.process:run('true').code, 0)
			rejects(function()
				box.process:run('cat', { input_path = box.artifacts .. '/missing-input' })
			end, 'No such')
			equal(box.process:run('true').code, 0)
			equal(box.process.foreground_busy, false)
			equal(#box.process.foreground_waiters, 0)

			local queued_marker = box.artifacts .. '/interrupted-queued-start'
			local queued_done = f.oneshot.new()
			local queued_ok, queued_err
			box.interrupt_notification = f.oneshot.new()
			box.process.foreground_busy = true
			assert(f.fibers.spawn(function()
				queued_ok, queued_err = pcall(function()
					box.process:run('touch ' .. quote(queued_marker))
				end)
				queued_done:signal()
			end))
			f.sleep.sleep(0.05)
			box.interrupted = true
			box.interrupt_notification:signal()
			f.fibers.perform(fiber_runtime.oneshot_op(queued_done))
			equal(queued_ok, false)
			assert(tostring(queued_err):find('Interrupted', 1, true))
			assert(not stat.stat(queued_marker), 'Interrupted queued command was launched')
			box.process:_release_foreground()
			equal(box.process.foreground_busy, false)
			equal(#box.process.foreground_waiters, 0)
			box.interrupted = nil
			box.interrupt_notification = nil
		end)
	end)
end

---@return nil
function tests.global_launch_gate_forwards_grant_when_granted_waiter_is_interrupted()
	with_session(function(box)
		local f = fiber_runtime.get()
		f.fibers.run(function()
			local second_dir, third_dir = box.artifacts .. '/grant-second', box.artifacts .. '/grant-third'
			assert(stat.mkdir(second_dir, 448))
			assert(stat.mkdir(third_dir, 448))
			local interrupted_reads = 0
			local second_state = setmetatable({ interrupt_notification = f.oneshot.new() }, {
				__index = function(_, key)
					if key == 'interrupted' then
						interrupted_reads = interrupted_reads + 1
						return interrupted_reads >= 2
					end
				end,
			})
			local second_process = process.new(second_dir, second_state)
			local third_process = process.new(third_dir, {})
			local handoff_seen, first_done, second_done, third_done = f.oneshot.new(), f.oneshot.new(),
				f.oneshot.new(), f.oneshot.new()
			local allow_handoff = false
			local read_handoff = box.process._read_handoff
			box.process._read_handoff = function(self, handle)
				local pgid = read_handoff(self, handle)
				if pgid and not allow_handoff then handoff_seen:signal(); return nil end
				return pgid
			end
			local first, second_ok, second_err, third
			assert(f.fibers.spawn(function()
				first = box.process:run('sleep 0.2')
				first_done:signal()
			end))
			f.fibers.perform(fiber_runtime.oneshot_op(handoff_seen))
			assert(f.fibers.spawn(function()
				second_ok, second_err = pcall(function()
					second_process:run('touch ' .. quote(second_dir .. '/unexpected-launch'))
				end)
				second_done:signal()
			end))
			f.sleep.sleep(0)
			assert(f.fibers.spawn(function()
				third = third_process:run('true')
				third_done:signal()
			end))
			f.sleep.sleep(0.02)
			allow_handoff = true
			f.fibers.perform(fiber_runtime.oneshot_op(second_done))
			f.fibers.perform(fiber_runtime.oneshot_op(third_done))
			f.fibers.perform(fiber_runtime.oneshot_op(first_done))
			box.process._read_handoff = read_handoff
			equal(second_ok, false)
			assert(tostring(second_err):find('Interrupted', 1, true))
			assert(not stat.stat(second_dir .. '/unexpected-launch'))
			equal(third.code, 0)
			equal(first.code, 0)
		end)
	end)
end

---@return nil
function tests.scope_cancellation_removes_queued_foreground_waiter()
	with_session(function(box)
		local f = fiber_runtime.get()
		f.fibers.run(function()
			box.process.foreground_busy = true
			local ready, done = f.oneshot.new(), f.oneshot.new()
			local child_scope, child_status
			assert(f.fibers.spawn(function()
				child_status = f.fibers.perform(f.fibers.run_scope_op(function(scope)
					child_scope = scope
					ready:signal()
					box.process:run('true')
				end))
				done:signal()
			end))
			f.fibers.perform(fiber_runtime.oneshot_op(ready))
			f.sleep.sleep(0)
			child_scope:cancel('injected scope cancellation')
			f.fibers.perform(fiber_runtime.oneshot_op(done))
			equal(child_status, 'cancelled')
			box.process:_release_foreground()
			equal(box.process.foreground_busy, false)
			equal(#box.process.foreground_waiters, 0)
			box.recovering = true
			equal(box.process:run('true').code, 0)
		end)
	end)
end

---@return nil
function tests.scope_cancellation_removes_queued_global_launch_waiter()
	with_session(function(box)
		local f = fiber_runtime.get()
		f.fibers.run(function()
			local second_artifacts = box.artifacts .. '/global-cancelled-process'
			assert(stat.mkdir(second_artifacts, 448))
			local second_process = process.new(second_artifacts, {})
			local handoff_seen, first_done = f.oneshot.new(), f.oneshot.new()
			local child_ready, child_done = f.oneshot.new(), f.oneshot.new()
			local allow_handoff = false
			local read_handoff = box.process._read_handoff
			box.process._read_handoff = function(self, handle)
				local pgid = read_handoff(self, handle)
				if pgid and not allow_handoff then handoff_seen:signal(); return nil end
				return pgid
			end
			local first, child_scope, child_status
			assert(f.fibers.spawn(function()
				first = box.process:run('true')
				first_done:signal()
			end))
			f.fibers.perform(fiber_runtime.oneshot_op(handoff_seen))
			assert(f.fibers.spawn(function()
				child_status = f.fibers.perform(f.fibers.run_scope_op(function(scope)
					child_scope = scope
					child_ready:signal()
					second_process:run('touch ' .. quote(second_artifacts .. '/unexpected-launch'))
				end))
				child_done:signal()
			end))
			f.fibers.perform(fiber_runtime.oneshot_op(child_ready))
			f.sleep.sleep(0)
			child_scope:cancel('injected global gate cancellation')
			f.fibers.perform(fiber_runtime.oneshot_op(child_done))
			equal(child_status, 'cancelled')
			assert(not stat.stat(second_artifacts .. '/unexpected-launch'))
			allow_handoff = true
			f.fibers.perform(fiber_runtime.oneshot_op(first_done))
			box.process._read_handoff = read_handoff
			equal(first.code, 0)
			box.recovering = true
			equal(box.recovery_process:run('true').code, 0)
		end)
	end)
end

---@return nil
function tests.failed_background_stop_remains_registered_for_root_retry()
	with_session(function(box)
		local f = fiber_runtime.get()
		f.fibers.run(function()
			local pid = box.process:start('sleep 30', box.artifacts .. '/tracked-background.log')
			local handle = assert(box.process.by_pid[pid])
			local shutdown = box.process._shutdown_group
			box.process._shutdown_group = function() error('injected containment failure') end
			rejects(function() box.process:stop(pid) end, 'injected containment failure')
			equal(box.process.by_pid[pid], handle)
			equal(box.process.active[handle], true)
			equal(handle.closed, nil)
			box.process._shutdown_group = shutdown
			box.process:stop(pid)
			equal(box.process.by_pid[pid], nil)
			equal(box.process.active[handle], nil)
		end)
	end)
end

---@return nil
function tests.credential_lease_serializes_launches_across_process_instances()
	with_session(function(box)
		local f = fiber_runtime.get()
		f.fibers.run(function()
			local second_artifacts = box.artifacts .. '/second-process'
			assert(stat.mkdir(second_artifacts, 448))
			local second_process = process.new(second_artifacts, {})
			local handoff_seen, first_done, second_done = f.oneshot.new(), f.oneshot.new(), f.oneshot.new()
			local allow_handoff = false
			local original_handoff = box.process._read_handoff
			box.process._read_handoff = function(self, handle)
				local pgid = original_handoff(self, handle)
				if pgid and not allow_handoff then handoff_seen:signal(); return nil end
				return pgid
			end

			local secret = 'credential lease test'
			local lease, fd, pipe_link, first_ok, first_result, second_result
			assert(f.fibers.spawn(function()
				first_ok, first_result = pcall(auth.with_password_fd, secret, function(supplied_fd, supplied_lease)
					fd, lease = supplied_fd, supplied_lease
					pipe_link = assert(unistd.readlink('/proc/self/fd/' .. fd))
					assert(not auth.lease_is_inheritable(lease))
					return box.process:run('sleep 0.2; IFS= read -r onbox_secret < /proc/self/fd/' .. fd
						.. '; test "$onbox_secret" = ' .. quote(secret), { inherit_fds = { lease } })
				end)
				first_done:signal()
			end))
			f.fibers.perform(fiber_runtime.oneshot_op(handoff_seen))
			assert(auth.lease_is_inheritable(lease), 'Lease was not enabled inside the launch gate')

			local second_marker = second_artifacts .. '/launched'
			assert(f.fibers.spawn(function()
				second_result = second_process:run('touch ' .. quote(second_marker)
					.. '; if test "$(readlink /proc/self/fd/' .. fd .. ' 2>/dev/null)" = '
					.. quote(pipe_link) .. '; then printf inherited; else printf clean; fi', { timeout = 0.05 })
				second_done:signal()
			end))
			f.sleep.sleep(0.05)
			assert(not stat.stat(second_marker), 'Second Process launched while credential inheritance was enabled')
			allow_handoff = true
			f.fibers.perform(fiber_runtime.oneshot_op(first_done))
			f.fibers.perform(fiber_runtime.oneshot_op(second_done))
			box.process._read_handoff = original_handoff
			assert(first_ok, first_result)
			assert(first_result.code == 0, 'Credential command failed (' .. tostring(first_result.code)
				.. '): ' .. tostring(first_result.stderr))
			assert(second_result.code == 0, 'Following command failed (' .. tostring(second_result.code)
				.. '): ' .. tostring(second_result.stderr))
			equal(second_result.stdout, 'clean')
			assert(not pcall(auth.lease_fd, lease), 'Credential lease was not retired after handoff')
		end)
	end)
end

---@return nil
function tests.concurrent_inline_requests_are_unique_and_leave_no_residue()
	with_session(function(box, temp)
		box.ssh.command = 'sh -c'
		local f = fiber_runtime.get()
		f.fibers.run(function()
			local done = { f.oneshot.new(), f.oneshot.new() }
			for i, data in ipairs({ string.rep('first-', 20000), string.rep('second-', 20000) }) do
				assert(f.fibers.spawn(function()
					assert(box.ssh:run('cat > ' .. quote(temp .. '/request-' .. i), { data = data }))
					done[i]:signal()
				end))
			end
			for i = 1, 2 do f.fibers.perform(fiber_runtime.oneshot_op(done[i])) end
			equal(util.read(temp .. '/request-1'), string.rep('first-', 20000))
			equal(util.read(temp .. '/request-2'), string.rep('second-', 20000))
		end)
		local caller_input = temp .. '/caller-input'
		util.write(caller_input, 'caller owned')
		box.ssh:run('cat > ' .. quote(temp .. '/caller-output'), { input_path = caller_input })
		equal(util.read(caller_input), 'caller owned')
		equal(util.read(temp .. '/caller-output'), 'caller owned')
		rejects(function() box.ssh:run('exit 9', { data = 'failed request' }) end, 'Remote command failed (9)')
		for name in dirent.files(box.artifacts) do
			assert(not name:match('^%.request%-'), 'Private request workspace was not removed: ' .. name)
		end
	end)
end

---@return nil
function tests.owned_process_registry_rejects_unknown_and_stops_legacy_processes()
	with_session(function(box)
		local kill = signals.kill
		local calls = 0
		signals.kill = function(...) calls = calls + 1; return kill(...) end
		local ok, err = pcall(function() box.process:stop(42424242) end)
		signals.kill = kill
		assert(not ok and tostring(err):find('Unknown or unowned', 1, true))
		equal(calls, 0)

		local pid = box.process:start('sleep 30', box.artifacts .. '/legacy.log')
		equal(box.process.legacy[pid].status, 'active')
		rejects(function() process.execute('true') end, 'forbidden')
		box.process:stop_all()
		equal(box.process.legacy[pid], nil)
		equal(box.process.tombstone[pid], true)
		box.process:stop(pid)
		equal(process.execute('true'), 0)
	end)
end

---@return nil
function tests.output_setup_failure_releases_gate_and_removes_workspace()
	with_session(function(box)
		local f = fiber_runtime.get()
		f.fibers.run(function()
			rejects(function() box.process:run('true', { log_path = box.artifacts }) end, '')
			equal(box.process:run('true').code, 0)
		end)
		for name in dirent.files(box.artifacts) do
			assert(not name:match('^%.process%-'), 'Process setup workspace was not removed: ' .. name)
		end
	end)
end

---@return nil
function tests.upload_creates_parent_directories_without_a_devicecode_runtime()
	with_session(function(box, temp)
		box.ssh.command = 'sh -c'
		local upload_source, destination = temp .. '/source', temp .. '/nested/path/destination'
		util.write(upload_source, 'uploaded over stdin')
		box.ssh:upload(upload_source, destination)
		equal(util.read(destination), 'uploaded over stdin')
		equal(bit.band(stat.stat(destination).st_mode, 511), 384)
	end)
end

---@return nil
function tests.recovery_ssh_uses_independent_process_manager_after_normal_manager_poisoning()
	with_session(function(box)
		box.ssh.command = 'sh -c'
		box.process:_poison('injected normal manager failure')
		rejects(function() box.ssh:run('true') end, 'Process manager is poisoned')
		box.recovering = true
		equal(box.ssh:run('printf recovered').stdout, 'recovered')
		equal(box.recovery_process.poison, nil)
	end)
end

---@return nil
function tests.remote_workspace_cleanup_uses_exact_registered_path()
	with_session(function(box, temp)
		box.ssh.command = 'sh -c'
		box.remote = temp .. '/devicecode-session'
		assert(process.execute('mkdir -p ' .. quote(box.remote)) == 0)
		util.write(box.remote .. '/artifact', 'temporary')
		box.ssh:workspace_created(box.remote)
		box.logs.stop = function() end
		equal(box:run(function() end), 0)
		equal(stat.stat(box.remote), nil)
	end)
end

---@return nil
function tests.phase_captures_and_stops_logs_without_preparing_a_devicecode_runtime()
	with_session(function(box, temp)
		local bin = temp .. '/bin'
		assert(process.execute('mkdir -p ' .. quote(bin)) == 0)
		util.write(bin .. '/logread', "#!/bin/sh\nprintf 'capture ready\\n'\n"
			.. "trap 'kill \"$child\" 2>/dev/null; wait \"$child\" 2>/dev/null; exit 0' TERM\n"
			.. "sleep 30 & child=$!\nwait \"$child\"\n")
		util.write(bin .. '/logger', '#!/bin/sh\nexit 0\n')
		assert(stat.chmod(bin .. '/logread', 448))
		assert(stat.chmod(bin .. '/logger', 448))
		box.ssh.command = 'env PATH=' .. quote(bin) .. ':"$PATH" sh -c'
		local body_ok, body_err = pcall(function()
			box:phase('example', function()
				local deadline = process.now() + 2
				while process.now() < deadline do
					if util.read(box.logs.path):find('capture ready', 1, true) then return end
					process.pause(0.02)
				end
				error('Background log capture did not start')
			end)
		end)
		-- Always stop the owned group, including after a fixture assertion fails.
		local stopped, stop_err = pcall(function() box.logs:stop() end)
		assert(body_ok, body_err)
		assert(stopped, stop_err)
		equal(box.logs.pid, nil)
		equal(box.logs.pid_path, nil)
		assert(util.read(box.logs.path):find('capture ready', 1, true))
	end)
end

---@return nil
function tests.failure_logs_survive_syslog_rollover_and_support_custom_filters()
	local lines = { 'radio: changing mode', 'radio: restarting' }
	for _ = 1, 1000 do lines[#lines + 1] = 'dropbear: Password auth succeeded' end
	local filtered = logs.failure_lines(table.concat(lines, '\n'), { 'radio' })
	equal(#filtered, 2)
	equal(filtered[1], lines[1])
	lines = {}
	for i = 1, 80 do lines[i] = 'radio: event ' .. i end
	filtered = logs.failure_lines(table.concat(lines, '\n'), { 'radio' })
	equal(#filtered, 70)
	equal(filtered[1], 'radio: event 11')
	equal(filtered[70], 'radio: event 80')
	equal(#logs.failure_lines('ERROR: broken\nunrelated\n', nil), 1)
end

---@return nil
function tests.failure_runs_diagnostics_rollback_and_lifo_cleanup_before_closing_ssh()
	with_session(function(box)
		local events = {}
		local stderr = io.stderr
		local output = {}
		rawset(io, 'stderr', { write = function(_, ...)
			for _, value in ipairs({ ... }) do output[#output + 1] = tostring(value) end
		end })
		local ok, err = pcall(function()
			box.logs.stop = function() events[#events + 1] = 'stop' end
			box.ssh.close = function() events[#events + 1] = 'close' end
			box:defer(function() events[#events + 1] = 'first' end)
			box:defer(function() events[#events + 1] = 'second'; error('cleanup error') end)
			local code = box:run(function() error('test failure') end, {
				diagnostics = function() events[#events + 1] = 'diagnostics' end,
				rollback = function() events[#events + 1] = 'rollback' end,
			})
			equal(code, 1)
			equal(table.concat(events, ','), 'stop,diagnostics,rollback,second,first,close')
			assert(table.concat(output):find('test failure', 1, true))
			assert(table.concat(output):find('cleanup error', 1, true))
		end)
		rawset(io, 'stderr', stderr)
		assert(ok, err)
	end)
end

---@return nil
function tests.success_runs_cleanup_without_invoking_rollback()
	with_session(function(box)
		local cleaned = false
		box.logs.stop = function() end
		box:defer(function() cleaned = true end)
		equal(box:run(function() end, {
			rollback = function() error('Rollback must not run after success') end,
		}), 0)
		equal(cleaned, true)
	end)
end

---@return nil
function tests.hup_int_and_term_enter_controlled_rollback_path()
	for _, target in ipairs({ signals.SIGHUP, signals.SIGINT, signals.SIGTERM }) do
		with_session(function(box)
			local signal = signals.signal
			local installed
			signals.signal = function(sig, handler, flags)
				if sig == target and type(handler) == 'function' and not installed then installed = handler end
				return signal(sig, handler, flags)
			end
			box.logs.stop = function() end
			local rolled_back = false
			local ok, result = pcall(function()
				return box:run(function()
					assert(installed, 'Signal handler was not installed')
					installed()
					process.pause(1)
				end, { rollback = function() rolled_back = true end })
			end)
			signals.signal = signal
			assert(ok, result)
			equal(result, 1)
			equal(rolled_back, true)
		end)
	end
end

---@return nil
function tests.interrupted_phase_still_stops_remote_capture_and_preserves_original_error()
	with_session(function(box)
		local remote_stopped, local_stopped = false, false
		box.logs.start = function(self) self.pid_path = '/tmp/own-log.pid'; self.pid = 123 end
		box.ssh.run = function()
			box.process:check_interrupted()
			remote_stopped = true
			return { stdout = '', stderr = '', code = 0 }
		end
		box.process.stop = function(_, pid) equal(pid, 123); local_stopped = true end
		rejects(function()
			box:phase('example', function() box.interrupted = true; error('original failure') end)
		end, 'original failure')
		equal(remote_stopped, true)
		equal(local_stopped, true)
		equal(box.recovering, nil)
	end)
end

---@return nil
function tests.devicecode_preserves_configuration_and_restores_persistent_file_presence()
	for _, existed in ipairs({ false, true }) do
		with_session(function(box, temp)
			local runtime, config_root = temp .. '/runtime', temp .. '/persistent'
			assert(process.execute('mkdir -p ' .. quote(runtime .. '/configs')) == 0)
			box.args.runtime, box.args.target = runtime, 'example'
			box.args.service = temp .. '/service'
			util.write(runtime .. '/main.lua', '-- original runtime\n')
			util.write(box.args.service, '#!/bin/sh\nexit 0\n')
			assert(stat.chmod(box.args.service, 448))
			local config = { hal = { data = { filesystem = { { name = 'config', root = config_root } } } },
				unrelated = { data = { value = 'preserved' } } }
			util.write(runtime .. '/configs/example.json', util.encode(config))
			if existed then
				assert(process.execute('mkdir -p ' .. quote(config_root)) == 0)
				util.write(config_root .. '/example.json', '{"original":"persistent"}')
			end
			box.ssh.run = function(_, command, opts)
				opts = opts or {}
				if opts.data then
					opts.input_path = box.artifacts .. '/request.stdin'
					util.write(opts.input_path, opts.data)
				end
				local result = box.process:run(command, opts)
				if opts.check ~= false then equal(result.code, 0) end
				return result
			end
			local app = devicecode.new(box)
			app:prepare()
			equal(app.original.unrelated.data.value, 'preserved')
			equal(app.persistent_existed, existed)
			app:backup()
			assert(app.backup_ready)
			assert(stat.stat(app.backup_path))
			app:write_config({ changed = true })
			assert(stat.stat(config_root .. '/example.json'))
			util.write(runtime .. '/main.lua', '-- changed runtime\n')
			util.write(runtime .. '/deployment-only.lua', '-- must be removed\n')
			app:restore_runtime()
			equal(util.read(runtime .. '/main.lua'), '-- original runtime\n')
			equal(stat.stat(runtime .. '/deployment-only.lua'), nil)
			if existed then equal(util.read(config_root .. '/example.json'), '{"original":"persistent"}')
			else equal(stat.stat(config_root .. '/example.json'), nil) end
			equal(util.decode(util.read(runtime .. '/configs/example.json')).unrelated.data.value, 'preserved')
		end)
	end
end

---@return nil
function tests.devicecode_snapshot_errors_abort_before_dependency_or_remote_mutation()
	for _, failure in ipairs({
		{ code = 255, detail = 'injected SSH failure' },
		{ code = 124, detail = 'injected timeout' },
		{ code = 45, detail = 'injected non-file configuration path' },
	}) do
		with_session(function(box)
			box.args.target = 'example'
			local calls = {}
			local bootstrap = util.encode({ hal = { data = { filesystem = {
				{ name = 'config', root = '/tmp/onbox-persistent' },
			} } } })
			box.ssh.run = function(_, command)
				calls[#calls + 1] = command
				if command:find('/configs/example.json', 1, true)
					and not command:find('if test -f', 1, true) then
					return { code = 0, stdout = bootstrap, stderr = '' }
				end
				if command:find('if test -f', 1, true) then
					return { code = failure.code, stdout = '', stderr = failure.detail }
				end
				return { code = 0, stdout = '', stderr = '' }
			end
			rejects(function() devicecode.new(box):prepare() end,
				'Cannot snapshot persistent configuration (exit ' .. failure.code .. ')')
			for _, command in ipairs(calls) do
				assert(not command:find('opkg', 1, true), 'Dependency mutation ran after snapshot failure')
				assert(not command:find('mkdir -p ' .. quote(box.remote), 1, true),
					'Remote workspace was created before snapshots completed')
			end
		end)
	end
end

---@return nil
function tests.devicecode_backup_faults_never_commit_or_enable_mutation()
	for _, mode in ipairs({ 'partial', 'corrupt' }) do
		with_session(function(box)
			local workspace_registered = false
			box.ssh.run = function(_, command)
				if command:find('mkdir -p', 1, true) then return { code = 0, stdout = '', stderr = '' } end
				if command:find('tar -czf', 1, true) then return { code = 0, stdout = '', stderr = '' } end
				error('Unexpected remote command: ' .. command)
			end
			box.ssh.workspace_created = function(_, path)
				equal(path, box.remote)
				workspace_registered = true
			end
			box.ssh.download = function(_, _, destination)
				util.write(destination, mode == 'corrupt' and 'not a tar archive' or 'partial archive')
				if mode == 'partial' then error('injected partial download') end
			end
			local app = devicecode.new(box)
			rejects(function() app:backup() end,
				mode == 'partial' and 'injected partial download' or 'Downloaded runtime backup is invalid')
			equal(workspace_registered, true)
			equal(app.backup_ready, false)
			equal(stat.stat(box.artifacts .. '/original-runtime.tar.gz.partial'), nil)
			equal(stat.stat(box.artifacts .. '/original-runtime.tar.gz'), nil)
		end)
	end
end

---@return nil
function tests.devicecode_registers_remote_workspace_before_archive_creation()
	with_session(function(box)
		local registered = false
		box.ssh.run = function(_, command)
			if command:find('mkdir -p', 1, true) then return { code = 0, stdout = '', stderr = '' } end
			equal(registered, true)
			error('injected remote tar failure')
		end
		box.ssh.workspace_created = function(_, path)
			equal(path, box.remote)
			registered = true
		end
		rejects(function() devicecode.new(box):backup() end, 'injected remote tar failure')
		equal(registered, true)
	end)
end

---@return nil
function tests.remote_workspace_is_registered_before_mkdir_acknowledgement()
	with_session(function(box)
		local registered = {}
		box.ssh.workspace_created = function(_, path) registered[path] = true end
		box.ssh.run = function(_, command)
			if command:find('mkdir -p', 1, true) then
				equal(registered[box.remote], true)
				error('injected lost mkdir acknowledgement')
			end
			error('Unexpected command: ' .. command)
		end
		rejects(function() devicecode.new(box):backup() end, 'injected lost mkdir acknowledgement')

		local log_remote = box.logs.remote
		box.ssh.run = function(_, command)
			equal(registered[log_remote], true)
			assert(command:find('mkdir -p', 1, true))
			error('injected lost log mkdir acknowledgement')
		end
		rejects(function() box.logs:start('lost-ack') end, 'injected lost log mkdir acknowledgement')
	end)
end

---@return nil
function tests.devicecode_refuses_deployment_without_committed_backup()
	with_session(function(box)
		local app = devicecode.new(box)
		rejects(function() app:deploy() end, 'committed local runtime backup')
		rejects(function() app:write_config({}) end, 'committed local runtime backup')
	end)
end

---@return nil
function tests.dependency_install_continues_after_opkg_update_error_and_checks_installed_tools()
	with_session(function(box, temp)
		local bin, log = temp .. '/bin', temp .. '/opkg.log'
		assert(process.execute('mkdir -p ' .. quote(bin)) == 0)
		util.write(bin .. '/opkg', '#!/bin/sh\nprintf "%s\\n" "$*" >> ' .. quote(log) .. '\n' .. [[
case "$1" in
    update) exit 1;;
    install)
        printf '#!/bin/sh\nexit 0\n' > ]] .. quote(bin .. '/onbox-required-command') .. '\n'
			.. 'chmod +x ' .. quote(bin .. '/onbox-required-command') .. '\n;;\nesac\n')
		assert(stat.chmod(bin .. '/opkg', 448))
		box.ssh.run = function(_, command, opts)
			return box.process:run('export PATH=' .. quote(bin) .. ':"$PATH";\n' .. command, opts)
		end
		local app = devicecode.new(box)
		app:ensure_dependencies({ commands = { ['onbox-required-command'] = 'onbox-package' } })
		local actions = util.read(log)
		assert(actions:find('update\ninstall onbox-package', 1, true))
		assert(stat.stat(bin .. '/onbox-required-command'))
		os.remove(bin .. '/onbox-required-command')
		util.write(bin .. '/opkg', '#!/bin/sh\nexit 0\n')
		rejects(function()
			app:ensure_dependencies({ commands = { ['onbox-required-command'] = 'onbox-package' } })
		end, 'Missing box dependencies')
	end)
end

---@return nil
function tests.modems_rediscover_by_imei_and_use_secondary_at_port()
	local calls = {}
	local box = { ssh = { run = function(_, command)
		calls[#calls + 1] = command
		if command == 'mmcli -L' then
			return { stdout = '/org/freedesktop/ModemManager1/Modem/2\n/org/freedesktop/ModemManager1/Modem/3' }
		elseif command == 'mmcli -m 3 -J' then return { code = 1 } end
		return { code = 0, stdout = util.encode({ modem = { generic = {
			['equipment-identifier'] = '123', state = 'disabled', device = 'usb-device',
			ports = { 'ttyUSB1 (at)', 'cdc-wdm0 (qmi)', 'ttyUSB2 (at)' },
		} } }) }
	end } }
	local inventory = modem.new(box):inventory()
	equal(inventory['123'].id, '2')
	equal(inventory['123'].at_port, '/dev/ttyUSB2')
	equal(#calls, 3)
end

---@return nil
function tests.modem_inventory_keeps_disabled_modems_without_at_ports()
	local box = { ssh = { run = function(_, command)
		if command == 'mmcli -L' then
			return { stdout = '/org/freedesktop/ModemManager1/Modem/3' }
		end
		equal(command, 'mmcli -m 3 -J')
		return { code = 0, stdout = util.encode({ modem = { generic = {
			['equipment-identifier'] = '000000000000003', state = 'disabled', model = 'EM06-E',
			ports = { 'cdc-wdm0 (qmi)', 'ttyUSB0 (qcdm)', 'ttyUSB1 (gps)', 'wwan0 (net)' },
		} } }) }
	end } }
	local modems = modem.new(box)
	local inventory = modems:inventory()
	local primary = assert(inventory['000000000000003'], 'Modem without AT ports must remain visible')
	equal(primary.id, '3')
	equal(primary.state, 'disabled')
	equal(primary.at_port, nil)
	box.args = { timeout = 10 }
	equal(modems:wait(inventory, 'disabled')[primary.imei].id, '3')
end

---@return nil
function tests.modem_wait_resets_missing_at_port_and_ignores_stale_ids()
	local healthy = { id = '2', state = 'connected', at_port = '/dev/ttyUSB7' }
	with_modem_inventory({
		{ primary = { id = '7', state = 'disabled' }, secondary = healthy },
		{ primary = { id = '7', state = 'disabled' }, secondary = healthy },
		{ secondary = healthy },
		{ primary = { id = '9', state = 'disabled', at_port = '/dev/ttyUSB3' }, secondary = healthy },
	}, function(modems, commands)
		local targets = { primary = { name = 'primary' }, secondary = { name = 'secondary' } }
		local current = modems:ensure_at_ports(targets)
		equal(current.primary.id, '9')
		equal(current.secondary.id, '2')
		equal(#commands, 1)
		equal(commands[1], 'mmcli -m 7 --reset')
	end)
end

---@return nil
function tests.modem_wait_bounds_missing_at_recovery_resets()
	with_modem_inventory({
		{ ['123'] = { id = '3', state = 'disabled' } },
		{ ['123'] = { id = '4', state = 'disabled' } },
		{ ['123'] = { id = '5', state = 'disabled' } },
	}, function(modems, commands)
		rejects(function() modems:ensure_at_ports({ ['123'] = { name = 'primary' } }) end,
			'Modem primary (…123) still has no AT port after 2 recovery resets')
		equal(#commands, 2)
		equal(commands[1], 'mmcli -m 3 --reset')
		equal(commands[2], 'mmcli -m 4 --reset')
	end)
end

---@return nil
function tests.modem_clean_boot_recovers_a_fresh_missing_at_modem_only()
	with_modem_inventory({
		{ ['123'] = { id = '3', state = 'disabled' } },
		{ ['123'] = { id = '3', state = 'disabled' } },
		{ ['123'] = { id = '4', state = 'disabled' } },
		{ ['123'] = { id = '4', state = 'disabled' } },
		{ ['123'] = { id = '5', state = 'disabled', at_port = '/dev/ttyUSB3' } },
	}, function(modems, commands)
		modems:clean_boot({ ['123'] = { name = 'primary' } }, true)
		equal(#commands, 2)
		equal(commands[1], 'mmcli -m 3 --reset')
		equal(commands[2], 'mmcli -m 4 --reset')
	end)
end

---@return nil
function tests.modem_wait_never_accepts_stale_id_after_recovery_reset()
	with_modem_inventory({
		{ ['123'] = { id = '3', state = 'disabled' } },
		{ ['123'] = { id = '3', state = 'disabled', at_port = '/dev/ttyUSB3' } },
	}, function(modems, commands)
		rejects(function() modems:ensure_at_ports({ ['123'] = { name = 'primary' } }) end,
			'Timed out after 10s waiting for AT ports')
		equal(#commands, 1)
	end)
end

---@return nil
function tests.modem_wait_remembers_all_previously_reset_ids()
	for _, stale_has_at in ipairs({ false, true }) do
		with_modem_inventory({
			{ ['123'] = { id = '3', state = 'disabled' } },
			{ ['123'] = { id = '4', state = 'disabled' } },
			{ ['123'] = { id = '3', state = 'disabled', at_port = stale_has_at and '/dev/ttyUSB3' or nil } },
			{ ['123'] = { id = '5', state = 'disabled', at_port = '/dev/ttyUSB3' } },
		}, function(modems, commands)
			local current = modems:ensure_at_ports({ ['123'] = { name = 'primary' } })
			equal(current['123'].id, '5')
			equal(#commands, 2)
			equal(commands[1], 'mmcli -m 3 --reset')
			equal(commands[2], 'mmcli -m 4 --reset')
		end)
	end
end

---@return nil
function tests.modem_wait_preserves_initial_id_exclusion_during_recovery()
	with_modem_inventory({
		{ ['123'] = { id = '4', state = 'disabled' } },
		{ ['123'] = { id = '3', state = 'disabled', at_port = '/dev/ttyUSB3' } },
		{ ['123'] = { id = '5', state = 'disabled', at_port = '/dev/ttyUSB3' } },
	}, function(modems, commands)
		local old_ids = { ['123'] = '3' }
		local current = modems:wait({ ['123'] = { name = 'primary' } }, 'disabled', old_ids, true)
		equal(current['123'].id, '5')
		equal(#commands, 1)
		equal(commands[1], 'mmcli -m 4 --reset')
		equal(old_ids['123'], '3')
	end)
end

---@return nil
function tests.modem_wait_does_not_reset_absent_failed_or_locked_modems()
	for _, state in ipairs({ 'absent', 'failed', 'locked' }) do
		local snapshot = state == 'absent' and {} or { ['123'] = { id = '3', state = state } }
		with_modem_inventory({ snapshot }, function(modems, commands)
			local expected = state == 'absent' and 'primary=absent' or 'became ' .. state
			rejects(function() modems:ensure_at_ports({ ['123'] = { name = 'primary' } }) end, expected)
			equal(#commands, 0)
		end)
	end
end

---@return nil
function tests.modem_wait_propagates_reset_failure_without_looping()
	with_modem_inventory({ { ['123'] = { id = '3', state = 'disabled' } } }, function(modems, commands)
		modems.box.ssh.run = function() error('reset rejected') end
		rejects(function() modems:ensure_at_ports({ ['123'] = { name = 'primary' } }) end, 'reset rejected')
		equal(#commands, 0)
	end)
end

---@return nil
function tests.modem_probe_rejects_missing_at_port_before_remote_actions()
	local modems = modem.new({ ssh = {
		upload = function() error('Must not upload for a missing AT port') end,
		run = function() error('Must not pause ModemManager for a missing AT port') end,
	} })
	rejects(function() modems:probe({ imei = '000000000000003' }, { 'AT' }) end,
		'No AT port reported by ModemManager for modem …0003')
end

---@return nil
function tests.modem_reset_waits_for_new_ids_instead_of_accepting_stale_disabled_state()
	local box = { args = { timeout = 10 }, ssh = {} }
	local modems = modem.new(box)
	local calls, reads = {}, 0
	modems.inventory = function()
		reads = reads + 1
		return { ['123'] = { id = reads <= 2 and '7' or '9', state = 'disabled' } }
	end
	box.ssh.run = function(_, command) calls[#calls + 1] = command end
	local saved = process.pause
	process.pause = function() end
	local ok, err = pcall(function() modems:clean_boot({ ['123'] = { id = 'old', name = 'example' } }) end)
	process.pause = saved
	assert(ok, err)
	equal(calls[1], 'mmcli -m 7 --reset')
	equal(reads, 3)
end

---@return nil
function tests.at_probe_uploads_once_and_resumes_modemmanager_with_a_watchdog()
	local uploads, commands = 0, {}
	local box = { args = { runtime = '/root/example' }, remote = '/tmp/example', ssh = {
		upload = function(_, path, destination)
			assert(stat.stat(path), 'Shared AT probe is missing')
			equal(destination, '/tmp/example/at_probe.lua')
			uploads = uploads + 1
		end,
		run = function(_, command)
			commands[#commands + 1] = command
			return { stdout = '{}', stderr = '', code = 0 }
		end,
	} }
	local modems = modem.new(box)
	for _ = 1, 2 do modems:probe({ at_port = '/dev/example' }, { 'AT', 'AT+CSQ' }) end
	equal(uploads, 1)
	equal(#commands, 2)
	assert(commands[1]:find("trap 'kill -CONT", 1, true))
	assert(commands[1]:find('(sleep 20;', 1, true))
	assert(commands[1]:find("'AT' 'AT+CSQ'", 1, true))
end

---@return nil
function tests.proc_stat_parser_handles_spaces_and_closing_parentheses_in_comm()
	local fields = {}
	for i = 1, 40 do fields[i] = tostring(i) end
	fields[2], fields[3], fields[19] = '321', '321', '987654'
	local identity = process.parse_proc_stat('321 (odd ) R comm with spaces) S ' .. table.concat(fields, ' ') .. '\n')
	equal(identity.pid, 321)
	equal(identity.comm, 'odd ) R comm with spaces')
	equal(identity.state, 'S')
	equal(identity.pgrp, 321)
	equal(identity.sid, 321)
	equal(identity.starttime, 987654)
end

---@return nil
function tests.containment_classifier_distinguishes_live_zombie_and_inconclusive()
	local reader, writer = assert(unistd.pipe())
	local pid = assert(unistd.fork())
	if pid == 0 then
		local child_ok = pcall(function()
			unistd.close(reader)
			assert(unistd.setpid('s'))
			assert(unistd.write(writer, 'R') == 1)
			unistd.close(writer)
			require('posix.time').nanosleep({ tv_sec = 30, tv_nsec = 0 })
		end)
		unistd._exit(child_ok and 0 or 1)
	end
	unistd.close(writer)
	local ok, err = pcall(function()
		equal(unistd.read(reader, 1), 'R')
		equal(process.classify_group(pid), 'LIVE')
		assert(signals.kill(pid, signals.SIGKILL or 9))
		local deadline = process.now() + 2
		local state
		repeat
			local file = io.open('/proc/' .. pid .. '/stat', 'r')
			if file then
				local content = file:read('*a')
				file:close()
				local parsed, identity = pcall(process.parse_proc_stat, content)
				if parsed then state = identity.state end
			end
			if state ~= 'Z' then require('posix.time').nanosleep({ tv_sec = 0, tv_nsec = 10000000 }) end
		until state == 'Z' or process.now() >= deadline
		equal(state, 'Z')
		local status, zombies = process.classify_group(pid)
		equal(status, 'ZOMBIES_ONLY')
		equal(zombies[1], pid)
	end)
	unistd.close(reader)
	pcall(signals.kill, pid, signals.SIGKILL or 9)
	pcall(wait.wait, pid)
	assert(ok, err)

	local files, open, stat_fn = dirent.files, fcntl.open, stat.stat
	dirent.files = function()
		local emitted = false
		return function() if not emitted then emitted = true; return '424242' end end
	end
	fcntl.open = function() return nil, 'injected permission failure', errno.EACCES end
	stat.stat = function() return {} end
	local classified, status = pcall(process.classify_group, 424242)
	dirent.files, fcntl.open, stat.stat = files, open, stat_fn
	assert(classified, status)
	equal(status, 'INCONCLUSIVE')
end

---@return nil
function tests.delayed_stop_identity_mismatch_retains_owner_and_sends_no_signal()
	local pid = assert(unistd.getpid())
	local identity = process.parse_proc_stat(util.read('/proc/' .. pid .. '/stat'))
	identity.starttime = identity.starttime + 1
	local owned = process.new('/tmp', {})
	local record = { pid = pid, pgid = identity.pgrp, identity = identity, status = 'active' }
	owned.legacy[pid] = record
	local kill, signals_sent = signals.kill, 0
	signals.kill = function(...) signals_sent = signals_sent + 1; return kill(...) end
	local ok, err = pcall(owned.stop, owned, pid)
	signals.kill = kill
	assert(not ok and tostring(err):find('identity mismatch', 1, true))
	equal(signals_sent, 0)
	equal(owned.legacy[pid], record)
	owned.legacy[pid] = nil
end

---@return nil
function tests.foreground_identity_mismatch_sends_no_group_signal()
	local pid = assert(unistd.getpid())
	local identity = process.parse_proc_stat(util.read('/proc/' .. pid .. '/stat'))
	identity.starttime = identity.starttime + 1
	local owned = process.new('/tmp', {})
	local f = fiber_runtime.get()
	local negative_signals = 0
	local kill = signals.kill
	signals.kill = function(target, signal)
		if target < 0 then negative_signals = negative_signals + 1 end
		return kill(target, signal)
	end
	local ok, err = pcall(function()
		f.fibers.run(function()
			local handle = { pgid = identity.pgrp, identity = identity, background = false,
				feeder_state = 'not_started' }
			rejects(function() owned:_shutdown_group(handle, 0) end, 'identity mismatch')
		end)
	end)
	signals.kill = kill
	assert(ok, err)
	equal(negative_signals, 0)
	assert(owned.poison and owned.poison:find('identity mismatch', 1, true))
end

---@return nil
function tests.identity_failure_before_feeder_uses_bounded_command_cleanup_only()
	local owned = process.new('/tmp', {})
	local f = fiber_runtime.get()
	local negative_signals, stdin_closed = 0, false
	local kill = signals.kill
	signals.kill = function(target, signal)
		if target < 0 then negative_signals = negative_signals + 1 end
		return kill(target, signal)
	end
	local ok, err = pcall(function()
		f.fibers.run(function()
			local handle = { feeder_state = 'not_started', completed = f.oneshot.new(),
				feeder_done = f.oneshot.new(), outcome_ready = f.oneshot.new(), outcome_sequence = 0,
				stdin = { terminate = function() stdin_closed = true end }, command = {
					shutdown_op = function() return f.op.always('exited', 0, nil, nil) end,
				} }
			rejects(function() owned:_shutdown_unidentified(handle, false) end,
				'cannot be established without a validated identity')
			equal(handle.feeder_state, 'not_started')
		end)
	end)
	signals.kill = kill
	assert(ok, err)
	equal(stdin_closed, true)
	equal(negative_signals, 0)
	assert(owned.poison, 'Unidentified command cleanup did not poison its Process')
end

---@return nil
function tests.interrupted_launch_before_identity_keeps_recovery_gate_available()
	with_session(function(box)
		local signal = signals.signal
		local interrupt_handler
		signals.signal = function(sig, handler, flags)
			if sig == signals.SIGINT and type(handler) == 'function' and not interrupt_handler then
				interrupt_handler = handler
			end
			return signal(sig, handler, flags)
		end
		box.logs.stop = function() end
		local read_handoff = box.process._read_handoff
		local interrupted = false
		box.process._read_handoff = function(self, handle)
			local pgid = read_handoff(self, handle)
			if pgid and not interrupted then
				interrupted = true
				assert(interrupt_handler, 'SIGINT handler was not installed')
				interrupt_handler()
				return nil
			end
			return pgid
		end
		local rolled_back = false
		local ok, code = pcall(function()
			return box:run(function()
				box.process:run('sleep 30')
			end, {
				diagnostics = function() end,
				rollback = function()
					equal(box.recovery_process:run('true').code, 0)
					rolled_back = true
				end,
			})
		end)
		box.process._read_handoff = read_handoff
		signals.signal = signal
		assert(ok, code)
		equal(code, 1)
		equal(interrupted, true)
		equal(rolled_back, true)
		assert(box.process.poison, 'Unidentified launch did not poison its owning Process')

		-- The leader was stopped through its command handle, but the deliberately
		-- unidentified handle remains registered for diagnosis. Release its local
		-- test resources so this fault-injection case cannot affect later specs.
		fiber_runtime.get().fibers.run(function()
			for handle in pairs(box.process.active) do box.process:_close_handle(handle, true) end
		end)
	end)
end

---@return nil
function tests.absent_background_leader_with_live_group_retains_owner_and_sends_no_signal()
	local fake_pid = 2147483646
	local owned = process.new('/tmp', {})
	local record = { pid = fake_pid, pgid = fake_pid, status = 'active',
		identity = { pid = fake_pid, pgrp = fake_pid, sid = fake_pid, starttime = 1 } }
	owned.legacy[fake_pid] = record
	local classify, kill, signals_sent = process.classify_group, signals.kill, 0
	process.classify_group = function(pgid)
		equal(pgid, fake_pid)
		return 'LIVE', {}
	end
	signals.kill = function(...) signals_sent = signals_sent + 1; return kill(...) end
	local ok, err = pcall(owned.stop, owned, fake_pid)
	process.classify_group, signals.kill = classify, kill
	assert(not ok and tostring(err):find('leader is absent', 1, true))
	equal(signals_sent, 0)
	equal(owned.legacy[fake_pid], record)
	owned.legacy[fake_pid] = nil
end

---@return nil
function tests.repeated_stop_after_tombstone_is_signal_free()
	local owned = process.new('/tmp', {})
	local pid = 234567
	owned.tombstone[pid] = true
	local kill, signals_sent = signals.kill, 0
	signals.kill = function(...) signals_sent = signals_sent + 1; return kill(...) end
	local ok, err = pcall(function() owned:stop(pid); owned:stop(pid) end)
	signals.kill = kill
	assert(ok, err)
	equal(signals_sent, 0)
end

---@return nil
function tests.workspace_removal_failure_is_reported_retained_and_retried()
	with_session(function(box)
		local f = fiber_runtime.get()
		f.fibers.run(function()
			local rmdir, injected = unistd.rmdir, false
			unistd.rmdir = function(path)
				if not injected and path:find('/.process-', 1, true) then
					injected = true
					return nil, 'injected workspace removal failure', errno.EACCES
				end
				return rmdir(path)
			end
			local ok, err = pcall(box.process.run, box.process, 'true')
			unistd.rmdir = rmdir
			assert(not ok and tostring(err):find('injected workspace removal failure', 1, true))
			local handle = next(box.process.active)
			assert(handle, 'Handle ownership was released after workspace cleanup failed')
			assert(handle.workspace_cleanup_errors and #handle.workspace_cleanup_errors > 0,
				'Workspace cleanup error was not retained')
			assert(stat.stat(handle.workspace), 'Failed workspace residue was not tracked on disk')
			box.process:stop_all()
			equal(next(box.process.active), nil)
			equal(stat.stat(handle.workspace), nil)
		end)
	end)
end

---@return nil
function tests.input_setup_is_transactional_before_launch_and_leaves_no_resources()
	with_session(function(box)
		local function fd_count()
			local count = 0
			for name in dirent.files('/proc/self/fd') do
				if name:match('^[0-9]+$') then count = count + 1 end
			end
			return count
		end
		local marker = box.artifacts .. '/unexpected-input-launch'
		local output = box.artifacts .. '/command.stdout'
		util.write(output, 'unchanged')
		local before = fd_count()
		rejects(function()
			box.process:run('touch ' .. quote(marker), { input_path = box.artifacts .. '/missing' })
		end, 'No such')
		assert(not stat.stat(marker), 'Child launched for missing input')
		equal(util.read(output), 'unchanged')
		equal(next(box.process.active), nil)

		local unreadable = box.artifacts .. '/unreadable-input'
		util.write(unreadable, 'secret')
		assert(stat.chmod(unreadable, 0))
		rejects(function() box.process:run('touch ' .. quote(marker), { input_path = unreadable }) end,
			'Permission denied')
		assert(stat.chmod(unreadable, 384))
		assert(not stat.stat(marker), 'Child launched for unreadable input')

		local empty = box.artifacts .. '/empty-input'
		util.write(empty, '')
		equal(box.process:run('true', { input_path = empty }).code, 0)
		equal(fd_count(), before)
		for name in dirent.files(box.artifacts) do
			assert(not name:match('^%.process%-'), 'Input setup left a process workspace: ' .. name)
		end
	end)
end

---@return nil
function tests.fifo_input_without_writer_is_rejected_without_blocking_or_launching()
	with_session(function(box)
		local fifo = box.artifacts .. '/input.fifo'
		local marker = box.artifacts .. '/unexpected-fifo-launch'
		assert(stat.mkfifo(fifo, 384))
		local function fd_count()
			local count = 0
			for name in dirent.files('/proc/self/fd') do
				if name:match('^[0-9]+$') then count = count + 1 end
			end
			return count
		end
		local before, started = fd_count(), process.now()
		rejects(function()
			box.process:run('touch ' .. quote(marker), { input_path = fifo })
		end, 'Unsupported process input type')
		assert(process.now() - started < 0.5, 'FIFO validation blocked without a writer')
		assert(not stat.stat(marker), 'Child launched for unsupported FIFO input')
		equal(fd_count(), before)
		equal(next(box.process.active), nil)
	end)
end

---@return nil
function tests.legacy_start_reads_exact_preopened_inode_after_path_replacement()
	with_session(function(box)
		local input = box.artifacts .. '/legacy-input'
		local log = box.artifacts .. '/legacy-exact-fd.log'
		util.write(input, 'original inode content')
		local replacement = input .. '.replacement'
		local script = 'printf replacement > ' .. quote(replacement) .. '; mv ' .. quote(replacement)
			.. ' ' .. quote(input) .. '; cat; sleep 0.2'
		local pid = box.process:start('sh -c ' .. quote(script), log, input)
		local deadline = process.now() + 2
		while process.now() < deadline do
			local file = io.open(log, 'r')
			local content = file and file:read('*a') or ''
			if file then file:close() end
			if content == 'original inode content' then break end
			require('posix.time').nanosleep({ tv_sec = 0, tv_nsec = 10000000 })
		end
		equal(util.read(log), 'original inode content')
		equal(util.read(input), 'replacement')
		box.process:stop(pid)
		box.process:stop(pid)
	end)
end

---@return nil
function tests.legacy_start_setup_and_handoff_failures_release_all_ownership()
	with_session(function(box)
		local function fd_count()
			local count = 0
			for name in dirent.files('/proc/self/fd') do
				if name:match('^[0-9]+$') then count = count + 1 end
			end
			return count
		end
		local function verify_failure(expected, install, restore)
			local before = fd_count()
			install()
			local ok, err = pcall(box.process.start, box.process, 'sleep 30',
				box.artifacts .. '/injected-legacy.log')
			restore()
			assert(not ok and tostring(err):find(expected, 1, true),
				'Expected injected failure containing: ' .. expected .. ', got: ' .. tostring(err))
			equal(fd_count(), before)
			equal(next(box.process.legacy), nil)
			local pid = box.process:start('sleep 30', box.artifacts .. '/recovery-legacy.log')
			box.process:stop(pid)
		end

		local mkdtemp = stdlib.mkdtemp
		verify_failure('injected mkdtemp failure', function()
			stdlib.mkdtemp = function(template)
				if template:find('/.legacy-', 1, true) then error('injected mkdtemp failure') end
				return mkdtemp(template)
			end
		end, function() stdlib.mkdtemp = mkdtemp end)

		local chmod = stat.chmod
		verify_failure('injected chmod failure', function()
			stat.chmod = function(path, mode)
				if path:find('/.legacy-', 1, true) then return nil, 'injected chmod failure' end
				return chmod(path, mode)
			end
		end, function() stat.chmod = chmod end)

		verify_failure('Cannot start background process', function()
			stdlib.mkdtemp = function(template)
				local workspace = assert(mkdtemp(template))
				assert(stat.mkdir(workspace .. '/ready', 448))
				return workspace
			end
		end, function() stdlib.mkdtemp = mkdtemp end)

		local write = util.write
		verify_failure('injected release marker failure', function()
			util.write = function(path, content)
				if path:match('/release$') then error('injected release marker failure') end
				return write(path, content)
			end
		end, function() util.write = write end)
	end)
end

---@return nil
function tests.input_read_failure_obeys_first_publication_without_stream_leaks()
	with_session(function(box)
		local f = fiber_runtime.get()
		local fdopen = f.file.fdopen
		local input_path = box.artifacts .. '/injected-input'
		util.write(input_path, 'input')
		local closes = 0
		local function run_with_stream(delay, command)
			local stream = { terminated = false, fd = nil }
			function stream:read_some()
				if delay then f.sleep.sleep(delay) end
				return nil, 'injected input read failure'
			end
			function stream:close()
				closes = closes + 1
				if self.fd then unistd.close(self.fd); self.fd = nil end
				return true
			end
			function stream:terminate()
				self.terminated = true
				if self.fd then unistd.close(self.fd); self.fd = nil end
			end
			f.file.fdopen = function(fd, mode, filename)
				if filename == input_path and mode == 'r' then stream.fd = fd; return stream end
				return fdopen(fd, mode, filename)
			end
			local ok, result = pcall(box.process.run, box.process, command,
				{ input_path = input_path, timeout = 1 })
			f.file.fdopen = fdopen
			return ok, result
		end
		local before = closes
		local early_ok, early_err = run_with_stream(nil, 'sleep 0.2')
		assert(not early_ok and tostring(early_err):find('injected input read failure', 1, true))
		equal(closes, before + 1)
		local late_ok, late_result = run_with_stream(0.05, 'true')
		assert(late_ok, late_result)
		equal(late_result.code, 0)
		equal(closes, before + 2)
		equal(next(box.process.active), nil)
	end)
end

---@return nil
function tests.zzz_post_spawn_lease_retirement_failure_is_owned_and_contained()
	with_session(function(box)
		local start_error, negative_signals = nil, 0
		auth.with_password_fd('injected credential', function(_, lease)
			local close_lease, parse_stat, kill = auth.close_lease, process.parse_proc_stat, signals.kill
			local injected = false
			auth.close_lease = function(value)
				if not injected then injected = true; error('injected lease retirement failure') end
				return close_lease(value)
			end
			local parses = 0
			process.parse_proc_stat = function(content)
				parses = parses + 1
				if parses > 1 then error('injected identity capture failure') end
				return parse_stat(content)
			end
			signals.kill = function(pid, signal)
				if pid < 0 then negative_signals = negative_signals + 1 end
				return kill(pid, signal)
			end
			local ok, err = pcall(box.process.start, box.process, 'sleep 0.1',
				box.artifacts .. '/provisional.log', nil, { inherit_fds = { lease } })
			auth.close_lease, process.parse_proc_stat, signals.kill = close_lease, parse_stat, kill
			assert(not ok, 'Injected lease retirement unexpectedly succeeded')
			start_error = err
		end)
		assert(tostring(start_error):find('injected lease retirement failure', 1, true))
		assert(tostring(start_error):find('injected identity capture failure', 1, true))
		equal(negative_signals, 0)
		local owned_pid, record = next(box.process.legacy)
		assert(owned_pid and record, 'Unidentified post-spawn process was not retained')
		equal(record.status, 'provisional')
		equal(record.identity, nil)
		equal(box.process.tombstone[owned_pid], nil)
	end)
end

return tests
