package.path = package.path .. ';/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua'

local op = require "fibers.op"
local fiber = require 'fibers.fiber'
local file = require 'fibers.stream.file'
local sc = require 'fibers.utils.syscall'

local pollio = require 'fibers.pollio'
pollio.install_poll_io_handler()

local pin = {}
pin.__index = pin

local gpio_base
local gpio_path = "/sys/class/gpio"

-- Set the GPIO base
local function set_gpio_base()
    local f = file.popen("cat /sys/class/gpio/gpiochip*/base | head -n1", "r")
    local base = f:read()
    f:close()
    base = tonumber(base)
    if not base then return nil, 'could not determine gpio_base' end
    gpio_base = base
    return true, nil
end

-- Helper function to write to a GPIO file
local function write_gpio_file(path, value)
    local f, err = file.open(path, "w")
    if not f then return nil, err end
    f:write(value)
    f:close()
    return true, nil
end

-- Create a new pin instance
local function new_pin(gpio_num)
    local self = setmetatable({
        gpio_num = gpio_num,
        gpio_path = gpio_path .. "/gpio" .. (gpio_base + gpio_num)
    }, pin)
    return self
end

-- Export a GPIO pin
function pin:export()
    if sc.stat(self.gpio_path) then
        return true, nil
    end
    return write_gpio_file(gpio_path .. "/export", gpio_base + self.gpio_num)
end

-- Unexport a GPIO pin
function pin:unexport()
    return write_gpio_file(gpio_path .. "/unexport", gpio_base + self.gpio_num)
end

-- Set the direction of the GPIO pin to "in"
function pin:set_in()
    return write_gpio_file(self.gpio_path .. "/direction", "in")
end

-- Set the direction of the GPIO pin to "out"
function pin:set_out()
    return write_gpio_file(self.gpio_path .. "/direction", "out")
end

-- Write a high value to the GPIO pin
function pin:write_high()
    return write_gpio_file(self.gpio_path .. "/value", "1")
end

-- Write a low value to the GPIO pin
function pin:write_low()
    return write_gpio_file(self.gpio_path .. "/value", "0")
end

-- Set edge detection to none
function pin:edge_none()
    return write_gpio_file(self.gpio_path .. "/edge", "none")
end

-- Set edge detection to rising edge
function pin:edge_rising()
    return write_gpio_file(self.gpio_path .. "/edge", "rising")
end

-- Set edge detection to falling edge
function pin:edge_falling()
    return write_gpio_file(self.gpio_path .. "/edge", "falling")
end

-- Set edge detection to both rising and falling edges
function pin:edge_both()
    return write_gpio_file(self.gpio_path .. "/edge", "both")
end

-- Read the value from the GPIO pin
function pin:read()
    local f, err = file.open(self.gpio_path .. "/value", "r")
    if not f then return nil, err end
    local value = f:read()
    f:close()
    return value, nil
end

-- Operation to watch for a change in the value of a GPIO pin. can be used in a non-deterministic op.choice() selector
function pin:watch_op()
    local f = self.watch_file
    if not f then
        local err
        f, err = file.open(self.gpio_path .. "/value", "r")
        if not f then return nil, err end
        f:read() -- consume existing `pri` event, if any
        self.watch_file = f
    end
    local retval = pollio.fd_priority_op(f.io.fd):wrap(function ()
        f:seek(sc.SEEK_SET, 0)
        local state, err = f:read()
        f:close()
        self.watch_file = nil
        if err then return nil, err end
        return state, nil
    end)
    return retval
end

-- Operation to watch for a change in the value of a GPIO pin
function pin:watch()
    return self:watch_op():perform()
end

-- Initialize the GPIO base
local function initialize_gpio()
    local success, err = set_gpio_base()
    if not success then
        return nil, err
    end
    return true, nil
end

return {
    initialize_gpio = initialize_gpio,
    new_pin = new_pin,
}