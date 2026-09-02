local fibers = require 'fibers'
local attempts_counter = require 'services.hal.managers.modemcard.attempts_counter'
local modemcard = require 'services.hal.managers.modemcard'

local tests = {}

local function eq(actual, expected, message)
    assert(actual == expected, message or ('expected ' .. tostring(expected) .. ', got ' .. tostring(actual)))
end

local function new_logger()
    local logger = {
        errors = {},
        warnings = {},
    }

    function logger:error(entry)
        self.errors[#self.errors + 1] = entry
    end

    function logger:warn(entry)
        self.warnings[#self.warnings + 1] = entry
    end

    return logger
end

local function failed_driver(init_err)
    local driver = {}

    function driver:init()
        return init_err or 'missing required modem ports'
    end

    function driver:stop()
        return true, ''
    end

    return driver
end

local function run_failure(attempts, options)
    local logger = options.logger or new_logger()
    local reset_calls = 0
    local recovery_calls = 0
    local recovery_address
    local recovery = {}

    function recovery:get_device()
        return options.device, options.device_err or ''
    end

    function recovery:reset()
        reset_calls = reset_calls + 1
        if options.reset_ok == false then
            return false, options.reset_err or 'reset failed'
        end
        return true
    end

    local result
    fibers.run(function()
        result = modemcard._test.initialise_driver(
            options.address,
            failed_driver(options.init_err),
            function(address)
                recovery_calls = recovery_calls + 1
                recovery_address = address
                return recovery
            end,
            attempts,
            logger
        )
    end)

    return {
        result = result,
        logger = logger,
        recovery_calls = recovery_calls,
        recovery_address = recovery_address,
        reset_calls = reset_calls,
    }
end

function tests.test_successful_initialization_does_not_enter_recovery()
    local attempts = attempts_counter.new(3)
    local logger = new_logger()
    local driver = {}

    function driver:init()
        return ''
    end

    local recovery_calls = 0
    local result = modemcard._test.initialise_driver(
        '/org/freedesktop/ModemManager1/Modem/0',
        driver,
        function()
            recovery_calls = recovery_calls + 1
        end,
        attempts,
        logger
    )

    eq(result, driver)
    eq(recovery_calls, 0)
    eq(#logger.errors, 0)
    eq(#logger.warnings, 0)
end

function tests.test_three_attempts_share_usb_path_across_mmcli_addresses()
    local attempts = attempts_counter.new(3)
    local device = '/sys/devices/platform/usb1/1-1'
    local reset_calls = 0

    for index = 1, 3 do
        local result = run_failure(attempts, {
            address = '/org/freedesktop/ModemManager1/Modem/' .. tostring(index),
            device = device,
        })
        reset_calls = reset_calls + result.reset_calls
        eq(result.recovery_address, '/org/freedesktop/ModemManager1/Modem/' .. tostring(index))
        eq(result.recovery_calls, 1)
    end

    eq(reset_calls, 2)
    eq(attempts:remaining(device), 0)
end

function tests.test_attempt_budgets_are_independent_per_usb_path()
    local attempts = attempts_counter.new(3)
    local first = '/sys/devices/platform/usb1/1-1'
    local second = '/sys/devices/platform/usb1/1-2'

    eq(run_failure(attempts, { address = '1', device = first }).reset_calls, 1)
    eq(run_failure(attempts, { address = '2', device = second }).reset_calls, 1)
    eq(attempts:remaining(first), 2)
    eq(attempts:remaining(second), 2)
end

function tests.test_success_restores_full_attempt_budget()
    local attempts = attempts_counter.new(3)
    local device = '/sys/devices/platform/usb1/1-1'

    local should_reset, remaining = attempts:record_failure(device)
    eq(should_reset, true)
    eq(remaining, 2)

    attempts:record_success(device)
    eq(attempts:remaining(device), 3)
end

function tests.test_reappearance_after_exhaustion_starts_fresh_cycle()
    local attempts = attempts_counter.new(3)
    local device = '/sys/devices/platform/usb1/1-1'

    for index = 1, 3 do
        run_failure(attempts, { address = tostring(index), device = device })
    end
    eq(attempts:remaining(device), 0)

    local result = run_failure(attempts, { address = '4', device = device })
    eq(result.reset_calls, 1)
    eq(attempts:remaining(device), 2)
end

function tests.test_device_lookup_failure_does_not_consume_attempt()
    local attempts = attempts_counter.new(3)
    local logger = new_logger()
    local result = run_failure(attempts, {
        address = '1',
        device = nil,
        device_err = 'device unavailable',
        logger = logger,
    })

    eq(result.reset_calls, 0)
    eq(attempts:remaining('/sys/devices/platform/usb1/1-1'), 3)
    eq(#logger.errors, 1)
    eq(logger.errors[1].what, 'init_driver_failed')
    eq(logger.errors[1].retry, false)
end

function tests.test_recovery_driver_creation_failure_is_contained()
    local attempts = attempts_counter.new(3)
    local logger = new_logger()
    local result
    fibers.run(function()
        result = modemcard._test.initialise_driver(
            '1',
            failed_driver(),
            function()
                error('recovery constructor failed')
            end,
            attempts,
            logger
        )
    end)

    eq(result, nil)
    eq(#logger.errors, 1)
    eq(logger.errors[1].what, 'create_recovery_driver_failed')
    eq(logger.errors[1].retry, false)
    assert(logger.errors[1].err:find('recovery constructor failed', 1, true))
end

function tests.test_reset_failure_is_terminal_and_not_logged_as_retrying()
    local attempts = attempts_counter.new(3)
    local logger = new_logger()
    local device = '/sys/devices/platform/usb1/1-1'
    local result = run_failure(attempts, {
        address = '1',
        device = device,
        reset_ok = false,
        reset_err = 'reset command failed',
        logger = logger,
    })

    eq(result.result, nil)
    eq(result.reset_calls, 1)
    eq(attempts:remaining(device), 2)
    eq(#logger.errors, 1)
    eq(logger.errors[1].what, 'reset_driver_failed')
    eq(logger.errors[1].retry, false)
    eq(#logger.warnings, 0)
end

return tests
