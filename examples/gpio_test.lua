package.path = package.path .. ';/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua'
package.path = "../src/?.lua;../?.lua;" .. package.path

local op = require "fibers.op"
local fiber = require 'fibers.fiber'
local gpio = require 'gpio'

local function setup(pin)
    assert(pin:export())
    assert(pin:pull_up())
    assert(pin:set_in())
    assert(pin:edge_both())
    return pin
end

fiber.spawn(function ()
    gpio.initialize_gpio()

    local p1 = setup(gpio.new_pin(5))
    local p2 = setup(gpio.new_pin(6))
    local p3 = setup(gpio.new_pin(13))
    local p4 = setup(gpio.new_pin(19))

    while true do
        local status = op.choice(
            p1:watch_op():wrap(function (status)
                return status=="0" and "1: inserted" or "1: removed"
            end),
            p2:watch_op():wrap(function (status)
                return status=="0" and "2: inserted" or "2: removed"
            end),
            p3:watch_op():wrap(function (status)
                return status=="0" and "3: inserted" or "3: removed"
            end),
            p4:watch_op():wrap(function (status)
                return status=="0" and "4: inserted" or "4: removed"
            end)
        ):perform()
        print(status)
    end
end)

fiber.main()
