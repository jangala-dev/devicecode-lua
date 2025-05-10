local service = require "service"
local sleep = require "fibers.sleep"
local new_msg = require "bus".new_msg

local metrics_test = {
    name = "metrics_test"
}
metrics_test.__index = metrics_test

function metrics_test:_string_endpoint(ctx)
    local data_string = 'Hello World'

    while not ctx:err() do
        self.bus_conn:publish(new_msg({'metrics_test', 'string'}, {data = data_string}))
        sleep.sleep(1)
    end
end

function metrics_test:_subtable_endpoint(ctx)
    local data_string = 'Goodbye World'

    while not ctx:err() do
        self.bus_conn:publish(new_msg({'metrics_test', 'string', 'goodbye'}, {data = data_string}))
        sleep.sleep(1)
    end
end

-- lets make somthing to trigger a 200% change
function metrics_test:_percent_endpoint(ctx)
    local i = 1

    while not ctx:err() do
        self.bus_conn:publish(new_msg({'metrics_test', 'value', 'percent'}, {data = i}))
        self.bus_conn:publish(new_msg({'metrics_test', 'difference', 'percent'}, {data = i}))
        sleep.sleep(1)
        i = i + 1
    end
end

-- lets make somthing to trigger an absolute change of 5
function metrics_test:_absolute_endpoint(ctx)
    local i = 0

    while not ctx:err() do
        self.bus_conn:publish(new_msg({'metrics_test', 'absolute'}, {data = i}))
        sleep.sleep(1)
        i = i + 1
    end
end

-- blitz data to metrics and make metrics filter it by time
function metrics_test:_timed_endpoint(ctx)
    local i = 1

    while not ctx:err() do
        self.bus_conn:publish(new_msg({'metrics_test', 'timed'}, {data = i}))
        sleep.sleep(0.1)
        i = i + 1
    end
end

function metrics_test:start(ctx, bus_conn)
    self.bus_conn = bus_conn

    sleep.sleep(1)

    service.spawn_fiber('string endpoint', bus_conn, ctx, function (fctx)
        self:_string_endpoint(fctx)
    end)

    service.spawn_fiber('subtable endpoint', bus_conn, ctx, function (fctx)
        self:_subtable_endpoint(fctx)
    end)

    service.spawn_fiber('percent endpoint', bus_conn, ctx, function (fctx)
        self:_percent_endpoint(fctx)
    end)

    service.spawn_fiber('absolute endpoint', bus_conn, ctx, function (fctx)
        self:_absolute_endpoint(fctx)
    end)

    service.spawn_fiber('timed endpoint', bus_conn, ctx, function (fctx)
        self:_timed_endpoint(fctx)
    end)
end

return metrics_test
