local linux_mm = require 'services.hal.backends.modem.providers.linux_mm.impl'
local args = require 'services.hal.types.capability_args'
local cap_types = require 'services.hal.types.capabilities'
local driver = require 'services.hal.drivers.modem'
local channel = require 'fibers.channel'
local exec = require 'fibers.io.exec'
local op = require 'fibers.op'
local runfibers = require 'tests.support.run_fibers'
local T = {}

function T.typed_modes_reject_invalid_values_and_normalize_allowed_sets()
    local opts = assert(args.new.ModemSetModesOpts('4g', { '4g', '3g', '4g' }))
    assert(getmetatable(opts) == args.ModemSetModesOpts)
    assert(table.concat(opts.allowed, '|') == '3g|4g')
    for _, invalid in ipairs({ {}, { 'lte' }, { '4g', 'bad' }, { [2] = '4g' }, { foo = '4g' } }) do
        assert(args.new.ModemSetModesOpts('4g', invalid) == nil)
    end
    local sparse = { '2g', '3g', '4g', '5g' }
    sparse[2] = nil
    assert(args.new.ModemSetModesOpts('4g', sparse) == nil)
    assert(args.new.ModemSetModesOpts('5g', { '4g' }) == nil)
    assert(args.new.ModemSetModesOpts('any', { '4g' }) == nil)
    assert(args.new.ModemSetModesOpts('none', { '4g' }))
end

function T.parser_reads_actual_mmcli_mode_strings()
    local raw = assert(linux_mm._test.parse_modem_info_json([[{"modem":{"generic":{
      "supported-modes":["allowed: 2g, 3g, 4g; preferred: 4g", "allowed: 4g; preferred: none"],
      "current-modes":"allowed: 4g, 3g, 2g; preferred: 4g"
    }}}]]))
    local info = assert(linux_mm._test.parse_modes_info(raw))
    assert(#info.supported_modes == 2)
    assert(info.current_modes.preferred == '4g')
    assert(table.concat(info.current_modes.allowed, '|') == '2g|3g|4g')
    info = assert(linux_mm._test.parse_modes_info({
        supported_modes = ' allowed: 5g; preferred: none  ', current_modes = 'allowed: 5g; preferred: none',
    }))
    assert(#info.supported_modes == 1 and info.current_modes.allowed[1] == '5g')
end

function T.parser_does_not_invent_modes_for_missing_malformed_or_unknown_data()
    for _, supported in ipairs({ {}, '--', 'bad', { 'allowed: 6g; preferred: none' },
        { 'allowed: 3g,,4g; preferred: 4g' },
        { 'allowed: 4g; preferred: 5g' } }) do
        assert(linux_mm._test.parse_modes_info({ supported_modes = supported,
            current_modes = 'allowed: 4g; preferred: none' }) == nil)
    end
    assert(linux_mm._test.parse_modes_info({ supported_modes = 'allowed: 4g; preferred: none' }) == nil)
end

function T.backend_submits_both_options_and_propagates_command_failure()
    local original = exec.command
    local argv, command_failure
    exec.command = function(options)
        argv = options
        return { combined_output_op = function()
            return op.always(command_failure and 'rejected' or '', 'exited', command_failure and 1 or 0)
        end }
    end
    local ok, err = pcall(function()
        runfibers.run(function()
            local backend = setmetatable({ identity = { address = '7' } }, linux_mm._test.ModemBackend)
            assert(backend:set_modes('4g', { '4g', '3g' }))
            assert(argv[1] == 'mmcli' and argv[3] == '7')
            assert(argv[4] == '--set-allowed-modes=3g|4g' and argv[5] == '--set-preferred-mode=4g')
            assert(backend:set_modes('none', { '4g' }))
            assert(argv[5] == '--set-preferred-mode=none')
            command_failure = true
            local applied, reason = backend:set_modes('4g', { '3g', '4g' })
            assert(not applied and reason:find('rejected', 1, true))
        end)
    end)
    exec.command = original
    assert(ok, err)
end

function T.driver_exposes_modes_and_invalidates_cached_read_after_write()
    runfibers.run(function()
        local cap = assert(cap_types.new.ModemCapability('one', channel.new()))
        assert(cap.offerings.get and cap.offerings.set_modes)
        local modem = assert(driver.new('7', { debug = function() end, error = function() end }))
        local current = { preferred = 'none', allowed = { '3g', '4g' } }
        local reads = 0
        modem.backend = {
            read_modes = function()
                reads = reads + 1
                return { current_modes = current, supported_modes = { current } }, ''
            end,
            set_modes = function(_, preferred, allowed)
                current = { preferred = preferred, allowed = allowed }
                return true, ''
            end,
        }
        local ok, result = modem:get(args.new.ModemGetOpts('current_modes', math.huge))
        assert(ok and result.preferred == 'none')
        ok, result = modem:get(args.new.ModemGetOpts('supported_modes', math.huge))
        assert(ok and #result == 1 and reads == 1)
        assert(not modem:set_modes({ preferred = '4g', allowed = { '4g' } }))
        assert(modem:set_modes(args.new.ModemSetModesOpts('4g', { '4g' })))
        ok, result = modem:get(args.new.ModemGetOpts('current_modes', math.huge))
        assert(ok and result.preferred == '4g' and reads == 2)
    end)
end

return T
