local json = require "dkjson"
package.path = "./test_modem_driver/?.lua;./test_utils/?.lua;../src/?.lua;" .. package.path .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"
package.loaded["services.hal.mmcli"] = nil
package.loaded["services.hal.modem_driver"] = nil

local fiber = require "fibers.fiber"
local op = require "fibers.op"
local channel = require "fibers.channel"
local context = require "fibers.context"
local modem_driver = require "services.hal.modem_driver"
local sleep = require "fibers.sleep"
local bus_pkg = require "bus"

local dummy_service = {}
dummy_service.__index = dummy_service
dummy_service.name = "dummy_service"

local function test_command_manager_commands()
    local commands = {"connect", "disconnect", "restart", "enable", "disable"}

    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    fiber.spawn(function ()
        driver:command_manager()
    end)

    local command_q = driver.command_q

    for _, cmd_name in ipairs(commands) do
        local ret_chan = channel.new()
        local cmd_msg = {
            command = cmd_name,
            return_channel = ret_chan
        }
        command_q:put(cmd_msg)

        local ret_msg = ret_chan:get()
        assert(ret_msg == cmd_name, 'return mismatch: expected '..cmd_name..' received '..ret_msg)
    end

    ctx:cancel('tests done')
end

local function test_command_manager_command_not_exist()
    local expected_result = "command does not exist"
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    fiber.spawn(function ()
        driver:command_manager()
    end)

    local command_q = driver.command_q

    local ret_chan = channel.new()
    local cmd_msg = {
        command = 'foo',
        return_channel = ret_chan
    }
    command_q:put(cmd_msg)

    local ret_msg = ret_chan:get()
    assert(ret_msg == expected_result, 'return mismatch: expected '..expected_result..' received '..ret_msg)

    ctx:cancel('tests done')
end

local function test_state_monitor()
    local bg = context.background()
    local ctx = context.with_cancel(bg)
    local ctx2 = context.with_cancel(ctx)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local bus = bus_pkg.new({q_len=10, m_wild='#', s_wild='+', sep="/"})
    local bus_connection = bus:connect()
    local bus_connection_2 = bus:connect()

    fiber.spawn(function ()
        driver:state_monitor(bus_connection_2, 0)
    end)

    fiber.spawn(function ()
        sleep.sleep(1)
        ctx:cancel('test done')
    end)

    local modem_monitor_sub, err = bus_connection:subscribe("hal/capability/modem/0/info/state")
    if err ~= nil then error(err) end
    local states = {}

    while not ctx2:err() do
        local msg = op.choice(
            modem_monitor_sub:next_msg_op(),
            ctx2:done_op()
        ):perform()
        if msg == nil then break end
        table.insert(states, msg.payload)
    end

    local expected_states = {
        {type = 'initial', prev_state='disabled', curr_state=nil},
        {type = 'changed', prev_state='disabled', curr_state='enabling'},
        {type = 'changed', prev_state='enabling', curr_state='searching'},
        {type = 'changed', prev_state='searching', curr_state='disabling'},
        {type = 'changed', prev_state='disabling', curr_state='disabled'},
        {type = 'removed', prev_state=nil, cur_state=nil}
    }

    for i, state in ipairs(states) do
        assert(expected_states[i].type == state.type,
            string.format("type mismatch, expected %s got %s", expected_states[i].type, state.type))
        assert(expected_states[i].prev_state == state.prev_state,
            string.format("prev_state mismatch, expected %s got %s", expected_states[i].prev_state, state.prev_state))
        assert(expected_states[i].curr_state == state.curr_state,
            string.format("cur_state mismatch, expected %s got %s", expected_states[i].cur_state, state.cur_state))
    end
end

local function test_modem_driver_init()
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local err = driver:init()

    assert(err == nil, err)
end

local function test_modem_driver_at_port()
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local at_ports, err = driver:get("at_ports")
    assert(err == nil, err)
    assert(at_ports)

    local expected_ports = {"ttyUSB2", "ttyUSB3"}

    for i, port in ipairs(at_ports) do
        assert(port == expected_ports[i],
        string.format("port mismatch, expected %s got %s", expected_ports[i], port))
    end
end

local function test_modem_driver_invalid_get()
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local info, err =  driver:get("foo")
    assert(err)
    assert(info == nil)
end

-- How to test starts_with function when is local? Make a hook into the module?

fiber.spawn(function ()
    test_command_manager_commands()
    test_command_manager_command_not_exist()
    test_state_monitor()
    test_modem_driver_init()
    test_modem_driver_at_port()
    test_modem_driver_invalid_get()
    fiber.stop()
end)

print("running modem driver tests")
fiber.main()
print("passed")