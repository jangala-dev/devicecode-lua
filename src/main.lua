package.path = "../?.lua;" .. package.path .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local context = require 'fibers.context'
local sc = require 'fibers.utils.syscall'
local bus = require 'bus'
local service = require 'service'
local log = require 'services.log'
log.outfile = '/tmp/logs.log'
require 'fibers.pollio'.install_poll_io_handler()
require 'fibers.alarm'.install_alarm_handler()

local file_chunk = 0
local lines = 0

-- Copy the ubus_scripts
local status = os.execute("cp -r ./ubus_scripts/* /")

if status ~= 0 then
    log.error("Failed to copy ubus_scripts")
end

-- local hook_file = io.open("/tmp/hook_logs_" .. file_chunk .. ".log", "w")
local function hook(event, line)
    local info = debug.getinfo(2)
    local msg = string.format("%s:%d:%s\n", info.short_src, line, info.name or "<anon>")
    if hook_file then
        hook_file:write(msg)
        hook_file:flush()
    end

    lines = lines + 1
    if lines > 2000 then
        if file_chunk - 1 >= 0 then
            os.remove("/tmp/hook_logs_" .. (file_chunk - 1) .. ".log")
        end
        file_chunk = file_chunk + 1
        hook_file:close()
        hook_file = io.open("/tmp/hook_logs_" .. file_chunk .. ".log", "w")
        lines = 0
    end
end
-- debug.sethook(hook, "l")

local function count_dir_items(path)
    local count
    local p = io.popen('ls -1 "' .. path .. '" | wc -l')
    if p then
        local output = p:read("*all")
        count = tonumber(output)
        p:close()
    end
    return count
end

local function count_zombies()
    local count
    local p = io.popen('ps | grep -c " Z "')
    if p then
        local output = p:read("*all")
        count = tonumber(output)
        p:close()
    end
    return count
end

local function count_processes()
    local p = io.popen('ps | wc -l')
    if p then
        local output = p:read("*all")
        local count = tonumber(output)
        p:close()
        return count - 1 -- Subtract 1 for the header line
    end
end

-- Get the device type/version from command line arguments or environment
local device_version = arg[1] or os.getenv("DEVICE")

if not device_version then error("device version must be specified on command line or env variable") end

-- create the root context for the whole application
local bg_ctx = context.background()
local rootctx = context.with_value(bg_ctx, "device", device_version)

-- Load the device configuration
local device_config = require("devices/" .. rootctx:value("device"))

-- Initialise bus (current bus implementation doesn't take a context)
local bus = bus.new({ q_length = 10, m_wild = '#', s_wild = '+' })

local services = {}

local function launch_services()
    for _, service_name in ipairs(device_config.services) do
        local svce = require("services/" .. service_name)
        service.spawn(svce, bus, rootctx)
    end
end

-- The main control fiber
fiber.spawn(function()
    local pid = sc.getpid()
    -- Launch all the services for the specific device
    launch_services()

    -- Here we can add more code for the CLI or other controls
    while true do
        local base_open_fds = count_dir_items("/proc/" .. pid .. "/fd")
        local base_zombies = count_zombies()
        local processes = count_processes()
        print("main fiber sleeping, zombies:", base_zombies, "open fds:", base_open_fds, "processes:", processes)
        sleep.sleep(5)
        -- CLI or other control logic goes here
    end
end)


fiber.main()




