-- insert shim to stop mmcli execution on hardware
-- package.path = "./test_modem_driver/?.lua;./test_utils/?.lua;" .. package.path

-- purge any module caching of shimmed module
-- package.loaded["services.hal.mmcli"] = nil

local fiber = require "fibers.fiber"
local op = require "fibers.op"
local channel = require "fibers.channel"
local context = require "fibers.context"
local sleep = require "fibers.sleep"
local bus_pkg = require "bus"

-- load mmcli shim to emulate hardware
local test_utils = require "test_utils.utils"
local shim_dir = "./test_modem_driver/"

--
local function test_get_info()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local get_key = {"modem", "generic", "device"}

    local nil_get = driver.cache:get(get_key)

    assert(nil_get == nil, "cache should not have device set before get function is called")

    driver:get_info()

    local val_get = driver.cache:get(get_key)

    assert(val_get == "/sys/devices/platform/axi/1000120000.pcie/1f00300000.usb/xhci-hcd.1/usb3/3-1",
        "device did not match expected value")
end

local function test_get_at_ports()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local get_key = {"modem", "generic", "at_ports"}

    local nil_get = driver.cache:get(get_key)

    assert(nil_get == nil, "cache should not have at_ports set before get function is called")

    driver:get_at_ports()

    local at_ports = driver.cache:get(get_key)

    assert(at_ports, "at_ports expected table but got nil")
    assert(at_ports[1] == "ttyUSB2", "at_ports[1] expected ttyUSB2 but got " .. at_ports[1])
    assert(at_ports[2] == "ttyUSB3", "at_ports[2] expected ttyUSB3 but got " .. at_ports[2])
end

local function test_get()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local imei = driver:get("imei")

    assert(imei, "imei should not be nil")
    assert(imei == "867929068986654", "imei expected 867929068986654 but got " .. imei)
end

local function test_get_primary_port()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local expected_val = '/dev/cdc-wdm0'
    local primary_port = driver:primary_port()

    assert(primary_port == expected_val,
        "primary_port expected " .. expected_val .. " but got " .. (primary_port or "nil"))
end

local function test_modem_driver_invalid_get()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local info, err =  driver:get("foo")
    assert(err, "err expected error but got nil")
    assert(info == nil, "info expected nil but got " .. (info or "nil"))
end

local function test_modem_driver_init()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    local err = driver:init()

    assert(err == nil, err)
end

local function test_modem_driver_invalid_init()
    test_utils.update_shim_path(shim_dir, "no_modem_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    -- force the error to be a string rather than wrapper
    local err = string.format("%s", driver:init())

    local expected_err = "no modem found"

    assert(err == expected_err, string.format('init error expected %s but got %s', expected_err, err))
end
local function test_state_monitor()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
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

    -- cancel test after 1 second
    fiber.spawn(function ()
        sleep.sleep(1)
        ctx:cancel('test done')
    end)

    local modem_monitor_sub, err = bus_connection:subscribe("hal/capability/modem/0/info/state")
    if err ~= nil then error(err) end
    local states = {}

    -- collect state messages
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

    -- evaluate state_messages
    for i, state in ipairs(states) do
        assert(expected_states[i].type == state.type,
            string.format("type mismatch, expected %s got %s", expected_states[i].type, state.type))
        assert(expected_states[i].prev_state == state.prev_state,
            string.format("prev_state mismatch, expected %s got %s", expected_states[i].prev_state, state.prev_state))
        assert(expected_states[i].curr_state == state.curr_state,
            string.format("cur_state mismatch, expected %s got %s", expected_states[i].cur_state, state.cur_state))
    end
end

local function test_command_manager_commands()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
    local commands = {"disconnect", "reset", "enable", "disable", "inhibit"}

    local bg = context.background()
    local ctx = context.with_cancel(bg)

    local driver = modem_driver.new(context.with_cancel(ctx), 0)

    fiber.spawn(function ()
        driver:command_manager()
    end)

    local command_q = driver.command_q

    -- send commands to driver and check for the command name to be returned
    -- or in the case of inhibit true should be returned
    for _, cmd_name in ipairs(commands) do
        local ret_chan = channel.new()
        local cmd_msg = {
            command = cmd_name,
            return_channel = ret_chan
        }
        command_q:put(cmd_msg)

        local ret_msg = ret_chan:get()
        local res = ret_msg.result
        local err = ret_msg.err

        assert(err == nil, 'error expected nil but got '..(err or 'nil'))
        if cmd_name == 'inhibit' then assert(res == true, 'return mismatch: expected true, received '
            .. (res and "true" or "false"))
        else assert(res == cmd_name, 'return mismatch: expected '..cmd_name..', received '..res) end
    end

    ctx:cancel('tests done')
end

local function test_command_manager_command_not_exist()
    test_utils.update_shim_path(shim_dir, "default_shim")
    local modem_driver = test_utils.uncached_require("services.hal.modem_driver")
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
    local res = ret_msg.result
    local err = ret_msg.err

    assert(res == nil, 'expected res to be nil but got '..(res or 'nil'))
    assert(err == expected_result, 'err mismatch: expected '..expected_result..' received '..err)

    ctx:cancel('tests done')
end

-- How to test starts_with function when is local? Make a hook into the module?

fiber.spawn(function ()
    -- test_get_info()
    -- test_get_at_ports()
    -- test_get()
    -- test_get_primary_port()
    -- test_modem_driver_invalid_get()
    test_modem_driver_init()
    test_modem_driver_invalid_init()
    test_state_monitor()
    test_command_manager_commands()
    test_command_manager_command_not_exist()
    fiber.stop()
end)

print("running modem driver tests")
fiber.main()
print("passed")
