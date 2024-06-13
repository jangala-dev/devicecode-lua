package.path = package.path .. ';/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua'
package.path = "../src/?.lua;../?.lua;" .. package.path

local op = require "fibers.op"
local fiber = require 'fibers.fiber'
local gpio = require 'gpio'

local map = {
    {
        {["1"] = false, ["7"] = false, ["8"] = true},
        {["1"] = false, ["7"] = true,  ["8"] = true},
        {["1"] = true,  ["7"] = false, ["8"] = false},
        {["1"] = false, ["7"] = true,  ["8"] = false},
        {["1"] = true,  ["7"] = true,  ["8"] = true},
        {["1"] = true,  ["7"] = false, ["8"] = true}
    },
    {
        {["24"] = false, ["23"] = false, ["18"] = true},
        {["24"] = false, ["23"] = true,  ["18"] = true},
        {["24"] = true,  ["23"] = false, ["18"] = false},
        {["24"] = false, ["23"] = true,  ["18"] = false},
        {["24"] = true,  ["23"] = true,  ["18"] = true},
        {["24"] = true,  ["23"] = false, ["18"] = true}
    }
}

local function map_modem_to_sim(modem_index, sim_index)
    local pin_states = map[modem_index][sim_index]
    for pin_no, value in pairs(pin_states) do
        local pin = gpio.new_pin(pin_no)
        assert(pin:export())
        assert(pin:set_out())
        if value then assert(pin:write_high()) else assert(pin:write_low()) end
    end
end

fiber.spawn(function ()
    gpio.initialize_gpio()

    --set both en's to low
    local ens = {25, 12}
    for _, v in ipairs(ens) do
        local pin = gpio.new_pin(v)
        assert(pin:export())
        assert(pin:set_out())
        assert(pin:write_low())
    end
    map_modem_to_sim(2, 2)

    fiber.stop()
end)

fiber.main()
