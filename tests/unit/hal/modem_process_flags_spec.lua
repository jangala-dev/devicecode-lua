local T = {}

local function with_exec_supports(supports_parent_death_signal, fn)
    local saved_exec = package.loaded['fibers.io.exec']
    local saved_mod = package.loaded['services.hal.backends.modem.process_flags']

    package.loaded['fibers.io.exec'] = {
        supports = function(name)
            return name == 'parent_death_signal' and supports_parent_death_signal or false
        end,
    }
    package.loaded['services.hal.backends.modem.process_flags'] = nil

    local ok, a, b = pcall(fn)

    package.loaded['fibers.io.exec'] = saved_exec
    package.loaded['services.hal.backends.modem.process_flags'] = saved_mod

    if not ok then error(a, 0) end
    return a, b
end

function T.owned_monitor_flags_always_requests_process_group()
    with_exec_supports(false, function()
        local flags = require('services.hal.backends.modem.process_flags').owned_monitor_flags()
        assert(flags.process_group == true)
        assert(flags.parent_death_signal == nil)
        assert(flags.pdeathsig == nil)
    end)
end

function T.owned_monitor_flags_adds_parent_death_signal_only_when_supported()
    with_exec_supports(true, function()
        local flags = require('services.hal.backends.modem.process_flags').owned_monitor_flags()
        assert(flags.process_group == true)
        assert(flags.parent_death_signal == 'TERM')
        assert(flags.pdeathsig == nil)
    end)
end

return T
