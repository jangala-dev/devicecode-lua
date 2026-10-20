local posix = require 'posix'
local runner = require 'onbox.support.runner'
local process = require 'onbox.support.process'
local logs = require 'onbox.support.logs'
local devicecode = require 'onbox.support.devicecode'
local modem = require 'onbox.support.modem'
local util = require 'onbox.support.util'
local quote = process.quote

local tests = {}
local here = assert(posix.realpath(arg[0])):match('^(.*)/[^/]+$')
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

---@param path string
---@return nil
local function remove_tree(path)
    local info = posix.stat(path)
    if not info then return end
    if info.type == 'directory' then
        for name in posix.files(path) do
            if name ~= '.' and name ~= '..' then remove_tree(path .. '/' .. name) end
        end
        assert(posix.rmdir(path))
    else assert(os.remove(path)) end
end

---@param body fun(box: OnboxSession, temp: string): nil
---@return nil
local function with_session(body)
    local temp = assert(posix.mkdtemp('/tmp/onbox-support-XXXXXX'))
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
    rejects(function() runner.parse_args({ '--timeout', '0' }, repo, here) end, 'Timeout must be positive')
    rejects(function() runner.parse_args({ '--runtime', '/' }, repo, here) end, 'Runtime must name')
    rejects(function() runner.parse_args({ '--host' }, repo, here) end, 'Missing value')
    for _, flags in ipairs({ { '--ask-pass', '--ssh-key-auth' }, { '--ssh-key-auth', '--ask-pass' },
        { '--ask-pass', '--password-file', 'unused' }, { '--password-file', 'unused', '--ask-pass' } }) do
        rejects(function() runner.parse_args(flags, repo, here) end, 'Choose one of')
    end
end

---@return nil
function tests.local_commands_preserve_stdin_stderr_exit_status_and_timeout()
    with_session(function(box)
        local result = box.process:run("printf 'hello'; printf 'error' >&2; exit 7")
        equal(result.stdout, 'hello')
        equal(result.stderr, 'error')
        equal(result.code, 7)
        local source = box.artifacts .. '/input'
        util.write(source, 'input data')
        result = box.process:run('cat', { input_path = source })
        equal(result.stdout, 'input data')
        equal(result.code, 0)
        equal(box.process:run('sleep 10', { timeout = 0.1 }).code, 124)
        box.interrupted = true
        rejects(function() box.process:run('true') end, 'Interrupted')
        box.recovering = true
        equal(box.process:run('true').code, 0)
        equal(posix.stat(box.artifacts).mode:sub(-9), 'rwx------')
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
            assert(posix.chmod(box.args.service, 'rwx------'))
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
            app:write_config({ changed = true })
            assert(posix.stat(config_root .. '/example.json'))
            util.write(runtime .. '/main.lua', '-- changed runtime\n')
            app:restore_runtime()
            equal(util.read(runtime .. '/main.lua'), '-- original runtime\n')
            if existed then equal(util.read(config_root .. '/example.json'), '{"original":"persistent"}')
            else equal(posix.stat(config_root .. '/example.json'), nil) end
            equal(util.decode(util.read(runtime .. '/configs/example.json')).unrelated.data.value, 'preserved')
        end)
    end
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
        assert(posix.chmod(bin .. '/opkg', 'rwx------'))
        box.ssh.run = function(_, command, opts)
            return box.process:run('export PATH=' .. quote(bin) .. ':"$PATH";\n' .. command, opts)
        end
        local app = devicecode.new(box)
        app:ensure_dependencies({ commands = { ['onbox-required-command'] = 'onbox-package' } })
        local actions = util.read(log)
        assert(actions:find('update\ninstall onbox-package', 1, true))
        assert(posix.stat(bin .. '/onbox-required-command'))
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
            assert(posix.stat(path), 'Shared AT probe is missing')
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

return tests
