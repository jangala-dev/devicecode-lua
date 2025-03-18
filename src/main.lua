package.path = "../?.lua;" .. package.path .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local context = require 'fibers.context'
local bus = require 'bus'
local service = require 'service'
require 'fibers.pollio'.install_poll_io_handler()

-- Get the device type/version from command line arguments or environment
local device_version = arg[1] or os.getenv("DEVICE")

if not device_version then error("device version must be specified on command line or env variable") end

-- create the root context for the whole application
local bg_ctx = context.background()
local rootctx = context.with_value(bg_ctx, "device", device_version)

-- Load the device configuration
local device_config = require("devices/" .. rootctx:value("device"))

-- Initialise bus (current bus implementation doesn't take a context)
local bus = bus.new({q_len=10, m_wild='#', s_wild='+'})

local services = {}

local function launch_services()
    for _, service_name in ipairs(device_config.services) do
        local svce = require("services/" .. service_name)
        service.spawn(svce, bus, rootctx)
    end
end

-- The main control fiber
fiber.spawn(function()
    -- Launch all the services for the specific device
    launch_services()

    -- Here we can add more code for the CLI or other controls
    while true do
        print("main fiber sleeping")
        sleep.sleep(100)
        -- CLI or other control logic goes here
    end
end)

fiber.main()




