local service = require "service"
local sleep = require "fibers.sleep"
local fiber = require "fibers.fiber"
local bus_pkg = require "bus"
local new_msg = bus_pkg.new_msg
local context = require "fibers.context"

local function test_service_states()
    -- make a fake service
    local dummy_service = {}
    dummy_service.__index = dummy_service

    dummy_service.name = 'dummy-service'

    function dummy_service:start(ctx, bus_conn)
        --nothing
    end

    local bus = bus_pkg.new({q_len=10, m_wild='#', s_wild='+', sep="/"})
    local bus_connection = bus:connect()

    local bg_ctx = context.background()
    local ctx = context.with_cancel(bg_ctx)

    local expected_states = {'active', 'disabled'}
    local states = {}

    -- fiber to listen for service health updates
    fiber.spawn(function ()
        local service_health_sub = bus_connection:subscribe({ 'dummy-service', 'health' })
        while not ctx:err() do
            local msg = service_health_sub:next_msg()
            if msg.payload ~= '' then
                table.insert(states, msg.payload.state)
            end
        end
    end)

    service.spawn(dummy_service, bus, ctx)

    -- send shutdown signal to service
    bus_connection:publish(new_msg(
        { 'dummy-service', 'control', 'shutdown' },
        { cause = "shutdown-service" },
        { retained = true }
    ))

    -- a little time for messages to propagate
    sleep.sleep(0.1)

    ctx:cancel('shutdown')

    -- check service states
    for i=1, 2 do
        assert(states[i] == expected_states[i], "service states was "..(states[i] or 'nil').." expected "..expected_states[i])
    end

    assert(#states == 2, 'service should have gone through 2 states, '..#states..' detected')
end

local function test_fiber_states()
    local dummy_service = {}
    dummy_service.__index = dummy_service

    dummy_service.name = 'dummy-service'

    -- service spins up a fiber that waits for 0.1 seconds before exiting
    function dummy_service:start(ctx, bus_conn)
        service.spawn_fiber('sleep-fiber', bus_conn, ctx, function (fctx)
            sleep.sleep(0.1)
        end)
    end

    local bus = bus_pkg.new({q_len=10, m_wild='#', s_wild='+', sep="/"})
    local bus_connection = bus:connect()

    local bg_ctx = context.background()
    local ctx = context.with_cancel(bg_ctx)

    local expected_states = {'initialising', 'active', 'disabled'}
    local states = {}

    -- fiber to listen for fiber health updates
    fiber.spawn(function ()
        local fiber_health_sub = bus_connection:subscribe({ 'dummy-service', 'health', 'fibers', 'sleep-fiber' })
        while not ctx:err() do
            local msg = fiber_health_sub:next_msg()
            if msg.payload ~= '' then
                table.insert(states, msg.payload.state)
            end
        end
    end)

    -- let listening fiber spin up
    fiber.yield()

    service.spawn(dummy_service, bus, ctx)

    -- send shutdown signal to service
    bus_connection:publish(new_msg(
        { 'dummy-service', 'control', 'shutdown' },
        { cause = "shutdown-service" },
        { retained = true }
    ))

    -- let shutdown signal propagate
    sleep.sleep(0.2)

    ctx:cancel('shutdown')

    -- check fiber states
    for i=1, 3 do
        assert(states[i] == expected_states[i], "service states was "..(states[i] or 'nil').." expected "..expected_states[i])
    end

    assert(#states == 3, 'service should have gone through 3 states, '..#states..' detected')
end

local function check_fiber_state(bus_conn, service_name, fiber_name)
    local sub = bus_conn:subscribe({ service_name, 'health', 'fibers', fiber_name })
    local state_msg = sub:next_msg()
    sub:unsubscribe()
    return state_msg.payload.state
end

local function check_service_state(bus_conn, service_name)
    local sub = bus_conn:subscribe({ service_name, 'health' })
    local state_msg = sub:next_msg()
    sub:unsubscribe()
    return state_msg.payload.state
end

local function test_blocked_shutdown()
    local dummy_service = {}
    dummy_service.__index = dummy_service

    dummy_service.name = 'dummy-service'

    -- service will create a fiber that will run endlessly, therefore
    -- blocking the shutdown of the service
    function dummy_service:start(ctx, bus_conn)
        service.spawn_fiber('stuck-loop', bus_conn, ctx, function (fctx)
            local i = 0
            while true do
                i = i + 1
                fiber.yield()
            end
        end)
    end

    local bus = bus_pkg.new({q_len=10, m_wild='#', s_wild='+', sep="/"})
    local bus_connection = bus:connect()

    local bg_ctx = context.background()
    local ctx = context.with_cancel(bg_ctx)

    service.spawn(dummy_service, bus, ctx)

    -- send shutdown signal to service
    bus_connection:publish(new_msg(
        { 'dummy-service', 'control', 'shutdown' },
        { cause = "shutdown-service" },
        { retained = true }
    ))

    -- wait for messages to propegate
    sleep.sleep(0.1)

    local fiber_state = check_fiber_state(bus_connection, 'dummy-service', 'stuck-loop')
    assert(fiber_state == 'active', 'stuck-loop should be active but is '..fiber_state)

    local service_state = check_service_state(bus_connection, 'dummy-service')
    assert(service_state == 'active', 'dummy-service should be active but is '..service_state)
end

local function test_timed_shutdown()
    local dummy_service = {}
    dummy_service.__index = dummy_service

    dummy_service.name = 'dummy-service'

    -- service will spin up
    function dummy_service:start(ctx, bus_conn)
        service.spawn_fiber('time-dependant', bus_conn, ctx, function (fctx)
            sleep.sleep(0.2)
        end)
    end

    local bus = bus_pkg.new({q_len=10, m_wild='#', s_wild='+', sep="/"})
    local bus_connection = bus:connect()

    local bg_ctx = context.background()
    local ctx = context.with_cancel(bg_ctx)

    service.spawn(dummy_service, bus, ctx)

    -- send shutdown signal to service
    bus_connection:publish(new_msg(
        { 'dummy-service', 'control', 'shutdown' },
        { cause = "shutdown-service" },
        { retained = true }
    ))

    -- wait for service and fiber to spin up
    sleep.sleep(0.1)

    local fiber_state = check_fiber_state(bus_connection, 'dummy-service', 'time-dependant')
    assert(fiber_state == 'active', 'time-dependant should be active but is '..fiber_state)

    local service_state = check_service_state(bus_connection, 'dummy-service')
    assert(service_state == 'active', 'dummy-service should be active but is '..service_state)

    -- wait for fiber to finish
    sleep.sleep(0.3)

    fiber_state = check_fiber_state(bus_connection, 'dummy-service', 'time-dependant')
    assert(fiber_state == 'disabled', 'time-dependant should be disabled but is '..fiber_state)

    service_state = check_service_state(bus_connection, 'dummy-service')
    assert(service_state == 'disabled', 'dummy-service should be disabled but is '..service_state)
end

local function test_context_shutdown()
    local dummy_service = {}
    dummy_service.__index = dummy_service

    dummy_service.name = 'dummy-service'

    -- service creates a fiber that requires a context cancellation in order to exit
    function dummy_service:start(sctx, bus_conn)
        service.spawn_fiber('ctx-dependant', bus_conn, sctx, function (fctx)
            local i = 0
            while not fctx:err() do
                i = i + 1
                fiber.yield()
            end
        end)
    end

    local bus = bus_pkg.new({q_len=10, m_wild='#', s_wild='+', sep="/"})
    local bus_connection = bus:connect()

    local bg_ctx = context.background()
    local ctx = context.with_cancel(bg_ctx)

    service.spawn(dummy_service, bus, ctx)

    local fiber_state = check_fiber_state(bus_connection, 'dummy-service', 'ctx-dependant')
    assert(fiber_state == 'initialising', 'ctx-dependant should be initialising but is '..fiber_state)

    -- let fiber spin up
    sleep.sleep(0.1)

    fiber_state = check_fiber_state(bus_connection, 'dummy-service', 'ctx-dependant')
    assert(fiber_state == 'active', 'ctx-dependant should be active but is '..fiber_state)

    local service_state = check_service_state(bus_connection, 'dummy-service')
    assert(service_state == 'active', 'dummy-service should be active but is '..service_state)

    -- send shutdown signal to service
    bus_connection:publish(new_msg(
        { 'dummy-service', 'control', 'shutdown' },
        { cause = "shutdown-service" },
        { retained = true }
    ))

    -- wait for messages to propegate
    sleep.sleep(0.1)

    fiber_state = check_fiber_state(bus_connection, 'dummy-service', 'ctx-dependant')
    assert(fiber_state == 'disabled', 'ctx-dependant should be disabled but is '..fiber_state)

    service_state = check_service_state(bus_connection, 'dummy-service')
    assert(service_state == 'disabled', 'dummy-service should be disabled but is '..service_state)
end

fiber.spawn(function ()
    test_service_states()
    test_fiber_states()
    test_blocked_shutdown()
    test_timed_shutdown()
    test_context_shutdown()
    fiber.stop()
end)

print("starting service tests")
fiber.main()
print("tests complete")
