local json = require "dkjson"
local file = require "fibers.stream.file"
local queue = require "fibers.queue"
local fiber = require "fibers.fiber"
local sleep = require "fibers.sleep"

local StreamCommand = {}
StreamCommand.__index = StreamCommand

function StreamCommand.new(events_directory)
    local events_file, err = file.open(events_directory, "r")
    if err then return nil end
    local events_data = events_file:read_all_chars()

    local self = {}
    self.event_q = queue.new()
    self.events = json.decode(events_data).events
    return setmetatable(self, StreamCommand)
end

function StreamCommand:stdout_pipe()
    return {
        close = function () return end,
        lines = function ()
            local event_iterator = function ()
                local message = self.event_q:get()
                return message
            end
            return event_iterator
        end
    }
end

function StreamCommand:start()
    fiber.spawn(function ()
        for _, event in ipairs(self.events) do
            self.event_q:put(event.out)
            sleep.sleep(event.wait)
        end
    end)
end

function StreamCommand:wait()
    sleep.sleep(0.5)
end

return {new = StreamCommand.new}