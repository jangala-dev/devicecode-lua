local file = require "fibers.stream.file"
local sleep = require "fibers.sleep"
local fiber = require "fibers.fiber"
local json = require "dkjson"
local queue = require "fibers.queue"

local function script_path()
    local str = debug.getinfo(2, "S").source:sub(2)
    return str:match("(.*/)")
 end

local events_data, err = file.open(script_path().."monitor_states.json", "r")
if err ~= nil then
    error(err)
end
local events = json.decode(events_data:read_all_chars()).events

local FakePipe = {}
FakePipe.__index = FakePipe

function FakePipe.new(event_q)
    return setmetatable({stage = 1, event_q = event_q}, FakePipe)
end

function FakePipe:lines()
    local readline =  function ()
        local event = self.event_q:get()
        if event == nil then return nil end
        if event.message ~= nil then return event.message end
        local line = string.format("(%s) %s [%s] %s",
            event.connected and '+' or '-',
            event.address,
            event.manufacturer,
            event.model
        )
        return line
    end
    return readline
end

function FakePipe:close()
end

local FakeCmd = {}
FakeCmd.__index = FakeCmd

function FakeCmd.new()
    return setmetatable({stage = 1, event_q = queue.new()}, FakeCmd)
end

function FakeCmd:stdout_pipe()
    return FakePipe.new(self.event_q)
end

function FakeCmd:start()
    fiber.spawn(function ()
        for _, event in ipairs(events) do
            self.event_q:put(event)
            sleep.sleep(event.wait_after)
        end
    end)
end

function FakeCmd:wait()
    sleep.sleep(0.05)
end

local function monitor_modems()
    return FakeCmd.new()
end

return {monitor_modems = monitor_modems}