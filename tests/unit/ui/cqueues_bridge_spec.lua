local T = {}

local runfibers = require 'tests.support.run_fibers'

local function with_fake_bridge_modules(fn)
    local saved = {
        cqueues = package.loaded['cqueues'],
        fibers = package.loaded['fibers'],
        sleep = package.loaded['fibers.sleep'],
        wait = package.loaded['fibers.wait'],
        runtime = package.loaded['fibers.runtime'],
        poller = package.loaded['fibers.io.poller'],
        bridge = package.loaded['services.ui.cqueues_bridge'],
    }

    local captured = {
        sleep_deadlines = {},
        performed = {},
        choice_args = nil,
        old_step_calls = {},
    }

    local old_step = function(self, timeout)
        captured.old_step_calls[#captured.old_step_calls + 1] = { self = self, timeout = timeout }
        return 'old-step'
    end

    local fake_cqueues = {
        running = function() return false end,
        interpose = function(name, wrapper)
            assert(name == 'step')
            captured.wrapper = wrapper
            return old_step
        end,
    }

    local fake_fibers = {
        now = function() return 10.0 end,
        perform = function(op)
            captured.performed[#captured.performed + 1] = op
            return true
        end,
        choice = function(...)
            captured.choice_args = { ... }
            return { kind = 'choice', args = { ... } }
        end,
    }

    local fake_sleep = {
        sleep_until_op = function(deadline)
            captured.sleep_deadlines[#captured.sleep_deadlines + 1] = deadline
            return { kind = 'sleep_until', deadline = deadline }
        end,
    }

    local fake_wait = {
        waitable = function(_register, _step, _wrap)
            return { kind = 'waitable' }
        end,
    }

    local fake_runtime = {
        current_fiber = function() return nil end,
        yield = function() error('yield should not be called in these tests') end,
    }

    local fake_poller = {
        get = function()
            return {
                wait = function(_, _fd, _want, _task)
                    return { unlink = function() return false end }
                end,
            }
        end,
    }

    package.loaded['cqueues'] = fake_cqueues
    package.loaded['fibers'] = fake_fibers
    package.loaded['fibers.sleep'] = fake_sleep
    package.loaded['fibers.wait'] = fake_wait
    package.loaded['fibers.runtime'] = fake_runtime
    package.loaded['fibers.io.poller'] = fake_poller
    package.loaded['services.ui.cqueues_bridge'] = nil

    local ok, err = pcall(function()
        local bridge = require 'services.ui.cqueues_bridge'
        fn(bridge, captured, fake_fibers)
    end)

    package.loaded['cqueues'] = saved.cqueues
    package.loaded['fibers'] = saved.fibers
    package.loaded['fibers.sleep'] = saved.sleep
    package.loaded['fibers.wait'] = saved.wait
    package.loaded['fibers.runtime'] = saved.runtime
    package.loaded['fibers.io.poller'] = saved.poller
    package.loaded['services.ui.cqueues_bridge'] = saved.bridge

    if not ok then error(err, 0) end
end

function T.cqueues_bridge_uses_sleep_until_for_positive_timeout()
    with_fake_bridge_modules(function(bridge, captured)
        runfibers.run(function()
            bridge.install()
            local self = {
                timeout = function() return 1.5 end,
                events = function() return nil end,
                pollfd = function() return nil end,
            }
            local rv = captured.wrapper(self, nil)
            assert(rv == 'old-step')
        end)
        assert(#captured.sleep_deadlines == 1)
        assert(captured.sleep_deadlines[1] == 11.5)
        assert(#captured.performed == 1)
        assert(captured.performed[1].kind == 'sleep_until')
        assert(captured.old_step_calls[#captured.old_step_calls].timeout == 0.0)
    end)
end

function T.cqueues_bridge_uses_immediate_deadline_for_zero_timeout()
    with_fake_bridge_modules(function(bridge, captured)
        runfibers.run(function()
            bridge.install()
            local self = {
                timeout = function() return 0 end,
                events = function() return nil end,
                pollfd = function() return nil end,
            }
            local rv = captured.wrapper(self, nil)
            assert(rv == 'old-step')
        end)
        assert(#captured.sleep_deadlines == 1)
        assert(captured.sleep_deadlines[1] == 10.0)
        assert(#captured.performed == 1)
        assert(captured.performed[1].kind == 'sleep_until')
    end)
end

function T.cqueues_bridge_composes_event_and_timeout_when_fd_wait_is_present()
    with_fake_bridge_modules(function(bridge, captured, fake_fibers)
        fake_fibers.choice = function(...)
            captured.choice_args = { ... }
            return select(1, ...)
        end
        runfibers.run(function()
            bridge.install()
            local self = {
                timeout = function() return 2.0 end,
                events = function() return 'r' end,
                pollfd = function() return 7 end,
            }
            local rv = captured.wrapper(self, nil)
            assert(rv == 'old-step')
        end)
        assert(#captured.sleep_deadlines == 1)
        assert(captured.sleep_deadlines[1] == 12.0)
        assert(type(captured.choice_args) == 'table')
        assert(#captured.choice_args == 2)
        assert(captured.choice_args[1].kind == 'waitable')
        assert(captured.choice_args[2].kind == 'sleep_until')
        assert(#captured.performed == 1)
        assert(captured.performed[1].kind == 'waitable')
    end)
end

return T
