local channel = require "fibers.channel"
local fiber   = require "fibers.fiber"
local sleep = require 'fibers.sleep'

TelemetryEventSource = {
}
TelemetryEventSource.__index = TelemetryEventSource

function TelemetryEventSource.new(interval, message, messages_handler, bus_connection)
    return setmetatable({
        interval = interval,
        last_run = 0,
        message = message,
        state_request_channel = channel.new(),
        run_state = "stopped",
        message_handler = messages_handler,
        bus_connection = bus_connection
    }, TelemetryEventSource)
end

function TelemetryEventSource:stop()
    self.state_request_channel:put("stopped")
end

function TelemetryEventSource:run()
    self.state_request_channel:put("running")
end

function TelemetryEventSource:start(ctx)
    fiber.spawn(function()
        while true do
            if self.run_state == "running" then
                print("Running event source")
                local result = self.message_handler:execute_messages(self.message)
                if result then
                    self.bus_connection:publish({type="publish", topic=self.message.response_topic, payload=result, retained=false})
                end
                sleep.sleep(self.interval)
            else
                self.run_state = self.state_request_channel:get()
            end
        end
    end)
end

TelemetryAgent = {}
TelemetryAgent.__index = TelemetryAgent

function TelemetryAgent.new(bus_connection, subscription_topic, messages_handler)
    return setmetatable({
        bus_connection = bus_connection,
        subscription_topic = subscription_topic,
        messages_handler = messages_handler,
        events = {}
    }, TelemetryAgent)
end

function TelemetryAgent:configure(config)
    self:stop()
    for _, event in ipairs(config.events) do
        local eventSource = TelemetryEventSource.new(
            event.interval,
            event.message,
            self.messages_handler,
            self.bus_connection
        )
        table.insert(self.events, eventSource)
        eventSource:start()
    end
end

function TelemetryAgent:stop()
    for _, event in ipairs(self.events) do
        event:stop()
    end
end

function TelemetryAgent:run()
    for _, event in ipairs(self.events) do
        event:run()
    end
end

return TelemetryAgent