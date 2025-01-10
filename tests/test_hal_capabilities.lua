local capabilities = require "services.hal.hal_capabilities"
local queue = require "fibers.queue"
local fiber = require "fibers.fiber"
local assertions = require "test_utils.assertions"
local context = require "fibers.context"

local function test_capability()
    local ctx = context.with_cancel(context.background())
    local test_q = queue.new()
    local modem_cap = capabilities.new_modem_capability(test_q)

    local expected_result = {
        result = 'somthing'
    }

    fiber.spawn(function()
        local result = modem_cap:enable()
        assertions.assert_table(expected_result, result, "cap_return")
        ctx:cancel()
    end)

    local cmd = test_q:get()
    local expected_cmd = {
        command = "enable",
        args = nil
    }

    assertions.assert_table(expected_cmd, cmd, 'cmd')

    cmd.return_channel:put(expected_result)
    ctx:done_op():perform()
end

fiber.spawn(function()
    test_capability()
    fiber.stop()
end)

print("running hal capabilities tests")
fiber.main()
print("tests passed")
