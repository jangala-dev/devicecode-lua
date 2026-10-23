#!/usr/bin/env luajit
-- Offline checks: fake deployment, mmcli, service restarts and local UI responses.
local posix = require 'posix'
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

function T.pairs_come_from_capabilities_and_explicit_requests_must_change_the_modem()
    local original = pair('none', { '3g', '4g' })
    local supported = { original, pair('4g', { '3g', '4g' }) }
    local valid, invalid = runner.choose_pairs(original, supported)
    assert(modes.equal(valid, supported[2]))
    assert(not modes.equal(invalid, supported[1]) and not modes.equal(invalid, supported[2]))
    rejects(function() runner.choose_pairs(original, { original }) end)
    rejects(function() runner.choose_pairs(original, supported, original) end)
    rejects(function() runner.choose_pairs(original, supported, pair('5g', { '5g' })) end)
    rejects(function() runner.choose_pairs(pair('none', { '2g' }), supported) end)
    assert(modes.equal(runner.parse_pair(' allowed: 4g, 3g; preferred: 4g '), supported[2]))
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

function T.automatic_pairs_never_enable_2g_and_prefer_4g_over_3g()
    local original = pair('4g', { '3g', '4g' })
    local supported = { pair('none', { '2g' }), pair('none', { '3g' }), original, pair('none', { '4g' }) }
    local valid, invalid = runner.choose_pairs(original, supported)
    assert(modes.equal(valid, supported[4]))
    assert(not modes.includes(valid, '2g') and not modes.includes(invalid, '2g'))
    local alternate = runner.choose_pairs(supported[4], supported)
    assert(modes.equal(alternate, original))
    rejects(function() runner.choose_pairs(supported[1], supported) end)
    rejects(function() runner.choose_pairs(original, supported, supported[1]) end)
end

function T.phase_config_prioritizes_imei_overrides_and_preserves_other_settings()
    local original = { gsm = { rev = 8, data = { modems = {
        default = { signal_freq = 10, cellular_modes = pair('none', { '3g', '4g' }) },
        known = { { id_field = 'device', device = '/dev/modem', name = 'primary', autoconnect = true },
            { imei = 'other', name = 'secondary' } },
    } } } }
    local targets = { ['123'] = { info = { imei = '123', device = '/dev/modem' }, name = 'primary',
        valid = pair('4g', { '4g' }) } }
    local config = runner.phase_config(original, targets, 'valid', 2)
    local first = config.gsm.data.modems.known[1]
    assert(config.gsm.rev == 10 and first.imei == '123' and first.id_field == 'imei' and first.device == nil)
    assert(first.name == 'primary' and first.autoconnect and first.signal_freq == 10)
    assert(modes.equal(first.cellular_modes, targets['123'].valid))
    assert(config.gsm.data.modems.known[3].imei == 'other')
    assert(#original.gsm.data.modems.known == 2 and original.gsm.rev == 8)
    assert(original.gsm.data.modems.known[1].cellular_modes == nil)
end

function T.ui_warning_requires_matching_service_modem_requested_pair_and_level()
    local expected = pair('4g', { '4g' })
    local target = { name = 'primary' }
    local record = { service = 'gsm', level = 'warn', what = 'cellular_modes_unsupported',
        payload = { modem = 'primary', requested = expected } }
    local response = { records = { record } }
    assert(runner.find_record(response, target, expected, record.what) == record)
    for _, change in ipairs({ { 'level', 'info' }, { 'service', 'hal' }, { 'what', 'other_warning' } }) do
        local old = record[change[1]]
        record[change[1]] = change[2]
        assert(not runner.find_record(response, target, expected, 'cellular_modes_unsupported'))
        record[change[1]] = old
    end
    record.payload.modem = 'secondary'
    assert(not runner.find_record(response, target, expected, record.what))
    record.payload.modem, record.payload.requested = 'primary', pair('none', { '4g' })
    assert(not runner.find_record(response, target, expected, record.what))
end

local function remove_tree(directory)
    for name in posix.files(directory) do
        if name ~= '.' and name ~= '..' then
            local child = directory .. '/' .. name
            if posix.stat(child).type == 'directory' then remove_tree(child) else assert(os.remove(child)) end
        end
    end
    assert(posix.rmdir(directory))
end

local function fixture(body, options)
    options = options or {}
    local temp = assert(posix.mkdtemp('/tmp/onbox-cellular-XXXXXX'))
    local original = pair('none', { '3g', '4g' })
    local supported = { original, pair('4g', { '4g' }) }
    local info = { imei = '123', id = '1', device = '/dev/modem', state = 'registered', model = 'example' }
    local base = { gsm = { rev = 1, data = { modems = { default = { enabled = true },
        known = { { id_field = 'device', device = '/dev/modem', name = 'primary', autoconnect = true } },
    } } }, ui = { data = { enabled = true, http = { port = 80 } } } }
    local state = { current = original, pid = 100, records = {}, builds = {}, deployments = 0,
        restarts = 0, queries = 0, time = 0, direct_sets = 0, diagnostics = 0, ui_queries = {} }
    local box = { args = { service = '/etc/init.d/devicecode', timeout = 6 }, artifacts = temp }
    box.phase = function(_, _, callback) callback() end
    box.run = function(_, callback, hooks)
        local ok, err = pcall(callback)
        box.recovering = true
        if not ok then
            state.error = tostring(err)
            hooks.diagnostics()
            hooks.rollback()
        end
        return ok and 0 or 1
    end
    box.logs = { diagnostics = function() state.diagnostics = state.diagnostics + 1 end }
    box.ssh = { run = function(_, command)
        if command:find('ubus call service list', 1, true) then
            return { code = 0, stdout = util.encode({ devicecode = { instances = {
                main = { pid = state.pid, running = state.pid ~= nil },
            } } }) }
        elseif command:find('curl ', 1, true) then
            assert(command:find('/api/logs', 1, true))
            assert(command:find('http://127.0.0.1:80', 1, true))
            local source = command:find('?boot=true', 1, true) and 'boot' or 'recent'
            state.ui_queries[source] = (state.ui_queries[source] or 0) + 1
            if options.ui_response then return options.ui_response(state, source) end
            return { code = 0, stdout = util.encode({ ok = true, records = state.records }) }
        elseif command:find('--set-allowed-modes=', 1, true) then
            state.direct_sets = state.direct_sets + 1
            state.current = original
            return { code = 0, stdout = '' }
        else
            assert(command:find("mmcli -m '" .. info.id .. "' -J", 1, true), command)
            state.queries = state.queries + 1
            local advertised = {}
            for _, candidate in ipairs(supported) do advertised[#advertised + 1] = raw(candidate) end
            return { code = 0, stdout = util.encode({ modem = { generic = {
                ['equipment-identifier'] = info.imei, ['current-modes'] = raw(state.current),
                ['supported-modes'] = advertised,
            } } }) }
        end
    end }
    local instance = runner.from_session(box)
    instance.now = function() return state.time end
    instance.pause = function(seconds) state.time = state.time + seconds end
    instance.modems = { inventory = function() return { ['123'] = info } end,
        diagnostic_commands = function() return {} end }
    instance.runtime = { original = base,
        prepare = function(self)
            if options.persistent then
                self.persistent_existed = true
                local config = tablex.deep_copy(base)
                config.gsm.data.modems.default.signal_freq = 17
                util.write(temp .. '/original-persistent.json', util.encode(config))
            end
        end,
        ensure_dependencies = function(_, dependencies)
            assert(dependencies.commands.curl and dependencies.commands.mmcli and dependencies.commands.ubus)
        end,
        backup = function() state.backed_up = true end,
        build = function(_, label, config)
            assert(state.backed_up and state.current)
            state.builds[#state.builds + 1] = { label = label, config = tablex.deep_copy(config) }
            return label .. '.tar.gz'
        end,
        deploy = function(self, archive)
            assert(archive == state.builds[#state.builds].label .. '.tar.gz')
            state.deployments, self.changed, state.pid = state.deployments + 1, true, nil
        end,
        write_config = function(_, config) state.config = config end,
        service = function(_, action)
            assert(action == 'restart')
            state.restarts = state.restarts + 1
            state.pid = options.stale_pid and 100 or 100 + state.restarts
            info.id = tostring(state.restarts + 1)
            local entry = state.config.gsm.data.modems.known[1]
            local request = entry.cellular_modes
            state.records = {}
            if request then
                local recognized = false
                for _, candidate in ipairs(supported) do recognized = recognized or modes.equal(request, candidate) end
                if recognized then state.current = tablex.deep_copy(request) end
                if options.changes_unsupported and not recognized then state.current = request end
                if not (options.missing_warning and not recognized) then
                    state.records[1] = { service = 'gsm', level = recognized and 'info' or 'warn',
                        what = recognized and 'cellular_modes_applied' or 'cellular_modes_unsupported',
                        payload = { modem = entry.name, requested = request } }
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

function T.full_scenario_rebuilds_three_times_and_restores_mmcli_original_modes()
    fixture(function(instance, state, original)
        assert(instance:run() == 0)
        assert(#state.builds == 3 and state.deployments == 3 and state.restarts == 3)
        assert(state.builds[1].label == '01-valid' and state.builds[2].label == '02-unsupported')
        assert(state.builds[3].label == '03-original')
        assert(modes.equal(state.current, original) and state.direct_sets == 0)
        assert(instance.summary[2].records['123'].level == 'warn')
        assert(modes.equal(instance.summary[2].actual['123'], instance.targets['123'].valid))
        assert(state.queries >= 4 and not state.restored_runtime)
    end)
end

function T.persistent_config_is_used_in_each_build()
    fixture(function(instance, state)
        assert(instance:run() == 0)
        for _, build in ipairs(state.builds) do assert(build.config.gsm.data.modems.default.signal_freq == 17) end
    end, { persistent = true })
end

function T.application_records_after_boot_capture_fills_are_found_in_recent_logs()
    fixture(function(instance, state)
        assert(instance:run() == 0)
        assert(state.ui_queries.recent == 3 and state.ui_queries.boot == 3)
        assert(instance.summary[1].records['123'].what == 'cellular_modes_applied')
        assert(instance.summary[2].records['123'].what == 'cellular_modes_unsupported')
        assert(instance.summary[3].records['123'].what == 'cellular_modes_applied')
    end, { ui_response = function(state, source)
        return { code = 0, stdout = util.encode({ ok = true, records = source == 'recent' and state.records or {} }) }
    end })
end

function T.evicted_recent_records_are_found_in_boot_logs_even_if_recent_query_fails()
    fixture(function(instance, state)
        assert(instance:run() == 0)
        assert(state.ui_queries.recent == 3 and state.ui_queries.boot == 3)
    end, { ui_response = function(state, source)
        if source == 'recent' then return { code = 22, stdout = '', stderr = 'HTTP error' } end
        return { code = 0, stdout = util.encode({ ok = true, records = state.records }) }
    end })
end

function T.modem_records_are_collected_across_buffers_and_polls()
    fixture(function(instance)
        instance.ui_url = 'http://127.0.0.1:80'
        local expected = pair('3g', { '3g' })
        for _, name in ipairs({ '123', '456', '789' }) do
            instance.targets[name] = { name = name, invalid = expected }
        end
        local records = instance:wait_logs('invalid', 'cellular_modes_unsupported', 'split')
        assert(records['123'].payload.modem == '123')
        assert(records['456'].payload.modem == '456')
        assert(records['789'].payload.modem == '789')
    end, { ui_response = function(state, source)
        local name
        if state.time == 0 then name = source == 'boot' and '123' or '456'
        elseif source == 'recent' then name = '789' end
        local records = name and { { service = 'gsm', level = 'warn', what = 'cellular_modes_unsupported',
            payload = { modem = name, requested = pair('3g', { '3g' }) } } } or {}
        return { code = 0, stdout = util.encode({ ok = true, records = records }) }
    end })
end

function T.missing_local_ui_warning_fails_and_restores_runtime_and_original_modes()
    fixture(function(instance, state, original)
        assert(instance:run() == 1)
        assert(state.error:find('cellular_modes_unsupported', 1, true))
        assert(#state.builds == 2 and state.restored_runtime and state.diagnostics == 1)
        assert(state.direct_sets == 1 and modes.equal(state.current, original))
    end, { missing_warning = true })
end

function T.unsupported_pair_that_changes_modem_modes_fails_and_rolls_back()
    fixture(function(instance, state, original)
        assert(instance:run() == 1)
        assert(state.error:find('02-unsupported mmcli modes', 1, true))
        assert(state.restored_runtime and state.direct_sets == 1 and modes.equal(state.current, original))
    end, { changes_unsupported = true })
end

function T.restart_must_replace_the_old_process_before_api_or_mode_checks()
    fixture(function(instance, state, original)
        assert(instance:run() == 1)
        assert(state.error:find('fresh service process', 1, true))
        assert(#instance.summary == 0 and state.restored_runtime and modes.equal(state.current, original))
    end, { stale_pid = true })
end

local names = util.keys(T)
for _, name in ipairs(names) do T[name](); print('PASS ' .. name) end
print(('%d cellular generation on-box runner tests passed'):format(#names))
