# Service structure
## service spawning
A service is created using service.spawn() which will follow the general form
- Publish service active under `<service_name>/health`
- Run service start function with arguments of bus connection and context (start function should be non-blocking)
- Create a shutdown fiber
- Shutdown fiber will 
    - wait for a shutdown message on `<service_name>/control/shutdown`
    - check all fibers' state on `<service_name>/health/fibers/+`
    - track which fibers are not showing 'disabled' state yet
    - once all fibers are showing disabled it will publish service state disabled and close

## fiber spawning
A service fiber is a fiber that is spawned with tracking features, spawning follows the steps
- Publish 'fiber init' under `<service_name>/health/fibers/<fiber_name>`
- create fiber and pass context with cancel and values fiber_name and service_name
- when fiber spins up 
    - publish 'fiber active'
    - run the given function with ctx as argument (this function should be blocking)
    - when given function returns, publish 'fiber disabled'

# How to use
## Spawn a service
```lua
service.spawn(service_obj, bus_connection, context)
```

## Spawn a service fiber
```lua
service.spawn(name, bus_connection, context, function (fiber_context)
    -- do stuff
end
)
```

# Example
```lua
local service = require "service"
local bus_mod = require "bus"
local context = require "fibers.context"
local op = require "fibers.op"
local sleep = require "fibers.sleep"

-- This is a dummy service
local dummy_service = {}
dummy_service.__index = dummy_service
dummy_service.name = 'dummy_service'

-- The start function should be non-blocking
function dummy_service:start(bus_conn, ctx)
    service.spawn_fiber('log-fiber', bus_conn, ctx, function (fib_ctx)
        while not fib_ctx:err() do
            print('fiber active')
            op.choice(
                sleep.sleep_op(1),
                fib_ctx:done_op()
            ):perform()
        end
    end)
end

local ctx = context.with_cancel(context.background)
local bus = bus_mod.new({q_len=10, m_wild='#', s_wild='+', sep="/"})

service.spawn(dummy_service, bus, ctx)

sleep.sleep(5)
ctx:cancel('shutdown')
```