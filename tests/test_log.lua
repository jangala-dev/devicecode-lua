-- test_log.lua
--
-- Service-level tests for the log service.
--
-- Each test spins up the log service in a child scope (or wires the singleton
-- connection directly), interacts with it via the bus, and asserts on bus-
-- published results.
--
-- Run standalone: luajit test_log.lua

local this_file = debug.getinfo(1, "S").source:match("@?([^/]+)$")
local is_entry_point = arg and arg[0] and arg[0]:match("[^/]+$") == this_file

if is_entry_point then
    package.path = "../vendor/lua-fibers/src/?.lua;"
        .. "../vendor/lua-trie/src/?.lua;"
        .. "../vendor/lua-bus/src/?.lua;"
        .. "../src/?.lua;"
        .. "./test_utils/?.lua;"
        .. package.path
        .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

    _G._TEST = true
end

local luaunit = require 'luaunit'
local fibers  = require 'fibers'
local perform = fibers.perform
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local busmod  = require 'bus'
local rxilog  = require 'rxilog'

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function make_bus()
    return busmod.new({ q_length = 100, s_wild = '+', m_wild = '#' })
end

-- Return a fresh singleton for each test.
local function fresh_log()
    package.loaded['services.log'] = nil
    local svc = require 'services.log'
    svc._conn = nil
    return svc
end

-- Start the log service in its own child scope; return the scope.
local function start_log(bus, root_scope, opts)
    local svc_scope = root_scope:child()
    svc_scope:spawn(function()
        package.loaded['services.log'] = nil
        local log_svc  = require 'services.log'
        local svc_conn = bus:connect()
        log_svc.start(svc_conn, opts or { name = 'log' })
    end)
    return svc_scope
end

local function stop_scope(svc_scope)
    svc_scope:cancel('test done')
    perform(svc_scope:join_op())
end

-- Receive up to `max` messages from `sub`, skipping lifecycle status msgs.
local function drain(sub, max)
    max = max or 20
    local msgs = {}
    for _ = 1, max do
        local ok, m = perform(op.choice(
            sub:recv_op():wrap(function(msg) return true, msg end),
            fibers.always(false)
        ))
        if not ok then break end
        if m.topic[1] ~= 'svc' then
            msgs[#msgs + 1] = m
        end
    end
    return msgs
end

-------------------------------------------------------------------------------
-- Unit tests: singleton API (no scheduler needed)
-------------------------------------------------------------------------------

TestLogSingleton = {}

function TestLogSingleton:setUp()
    self.log = fresh_log()
end

function TestLogSingleton:test_has_all_log_level_methods()
    for _, mode in ipairs(rxilog.modes) do
        luaunit.assertEquals(type(self.log[mode.name]), 'function',
            'missing log level method: ' .. mode.name)
    end
end

function TestLogSingleton:test_log_without_conn_does_not_error()
    luaunit.assertNil(self.log._conn)
    -- Must not raise even though no connection is wired up.
    self.log.info('no-conn test')
    self.log.warn('no-conn warn')
end

function TestLogSingleton:test_singleton_identity()
    local a = require 'services.log'
    local b = require 'services.log'
    luaunit.assertIs(a, b)
end

-------------------------------------------------------------------------------
-- Integration tests: bus publish behaviour
--
-- LuaUnit.run() is called inside fibers.run() at the entry point, so every
-- test method body already runs inside a fiber and may call perform() freely.
-------------------------------------------------------------------------------

TestLogBusPublish = {}

-- Wire the singleton connection manually (without running the full service)
-- and verify that a single log call produces exactly one bus message.
function TestLogBusPublish:test_info_publishes_to_bus()
    local log  = fresh_log()
    local bus  = make_bus()
    local conn = bus:connect()
    log._conn  = conn

    local sub = conn:subscribe({ 'logs', '+' })

    fibers.spawn(function()
        log.info('hello from test')
    end)

    local received = perform(op.choice(
        sub:recv_op(),
        sleep.sleep_op(1):wrap(function() return nil end)
    ))

    log._conn = nil

    luaunit.assertNotNil(received, 'expected one published log message')
    luaunit.assertEquals(received.topic[1], 'logs')
    luaunit.assertEquals(received.topic[2], 'info')
    luaunit.assertNotNil(received.payload.message)
    luaunit.assertNotNil(received.payload.timestamp)
    luaunit.assertStrContains(received.payload.message, 'hello from test')
end

-- Every rxilog level must produce a message on {'logs', <level>}.
function TestLogBusPublish:test_all_levels_publish_correct_topic()
    local log  = fresh_log()
    local bus  = make_bus()
    local conn = bus:connect()
    log._conn  = conn

    local sub = conn:subscribe({ 'logs', '+' })

    fibers.spawn(function()
        for _, mode in ipairs(rxilog.modes) do
            log[mode.name]('level test: ' .. mode.name)
        end
    end)

    local levels_seen = {}
    for _ = 1, #rxilog.modes do
        local msg = perform(op.choice(
            sub:recv_op(),
            sleep.sleep_op(1):wrap(function() return nil end)
        ))
        if msg then
            levels_seen[msg.topic[2]] = true
        end
    end

    log._conn = nil

    for _, mode in ipairs(rxilog.modes) do
        luaunit.assertTrue(levels_seen[mode.name],
            'no message published for level: ' .. mode.name)
    end
end

-- Payload must contain a non-empty string `message` and a positive `timestamp`.
function TestLogBusPublish:test_message_payload_fields()
    local log  = fresh_log()
    local bus  = make_bus()
    local conn = bus:connect()
    log._conn  = conn

    local sub = conn:subscribe({ 'logs', '+' })

    fibers.spawn(function()
        log.warn('payload field check')
    end)

    local msg = perform(op.choice(
        sub:recv_op(),
        sleep.sleep_op(1):wrap(function() return nil end)
    ))

    log._conn = nil

    luaunit.assertNotNil(msg)
    local payload = msg.payload
    luaunit.assertEquals(type(payload.message),   'string', 'message must be a string')
    luaunit.assertEquals(type(payload.timestamp), 'number', 'timestamp must be a number')
    luaunit.assertTrue(payload.timestamp > 0,               'timestamp must be positive')
    luaunit.assertStrContains(payload.message, 'WARN')
    luaunit.assertStrContains(payload.message, 'payload field check')
end

-- When _conn is nil, log calls must not publish anything to the bus.
function TestLogBusPublish:test_no_publish_without_connection()
    local log  = fresh_log()   -- _conn is nil
    local bus  = make_bus()
    local conn = bus:connect()

    local sub = conn:subscribe({ 'logs', '+' })

    fibers.spawn(function()
        log.info('should not be published')
    end)

    local count = 0
    perform(op.choice(
        sub:recv_op():wrap(function()
            count = count + 1
            return true
        end),
        sleep.sleep_op(0.05):wrap(function() return false end)
    ))

    luaunit.assertEquals(count, 0, 'no messages should be published when _conn is nil')
end

-------------------------------------------------------------------------------
-- Service lifecycle tests
--
-- These run the full log service in a child scope and verify the status
-- messages it retains on {'svc', 'log', 'status'}.
-------------------------------------------------------------------------------

TestLogServiceLifecycle = {}

function TestLogServiceLifecycle:test_publishes_starting_running_stopped()
    local root = fibers.current_scope()
    local bus  = make_bus()
    local conn = bus:connect()

    local status_sub = conn:subscribe({ 'svc', 'log', 'status' })
    local svc_scope  = start_log(bus, root)

    -- Collect 'starting' and 'running'.
    local states = {}
    for _ = 1, 2 do
        local msg = perform(op.choice(
            status_sub:recv_op(),
            sleep.sleep_op(1):wrap(function() return nil end)
        ))
        if msg and msg.payload then
            states[#states + 1] = msg.payload.state
        end
    end

    -- Trigger shutdown; expect 'stopped'.
    stop_scope(svc_scope)

    local msg = perform(op.choice(
        status_sub:recv_op(),
        sleep.sleep_op(1):wrap(function() return nil end)
    ))
    if msg and msg.payload then
        states[#states + 1] = msg.payload.state
    end

    local found = {}
    for _, s in ipairs(states) do found[s] = true end
    luaunit.assertTrue(found['starting'], "expected 'starting' status")
    luaunit.assertTrue(found['running'],  "expected 'running' status")
    luaunit.assertTrue(found['stopped'],  "expected 'stopped' status after cancel")
end

-- Once the service is running, log calls (via the singleton) are published.
function TestLogServiceLifecycle:test_service_publishes_log_entries()
    local root = fibers.current_scope()
    local bus  = make_bus()
    local conn = bus:connect()

    local log_sub    = conn:subscribe({ 'logs', '+' })
    local status_sub = conn:subscribe({ 'svc', 'log', 'status' })
    local svc_scope  = start_log(bus, root)

    -- Wait for the service to reach 'running' before logging.
    while true do
        local smsg = perform(op.choice(
            status_sub:recv_op(),
            sleep.sleep_op(1):wrap(function() return nil end)
        ))
        if not smsg then break end
        if smsg.payload and smsg.payload.state == 'running' then break end
    end

    -- The singleton _conn is now wired by the service; emit a message.
    local log = require 'services.log'
    log.info('lifecycle publish test')

    -- Drain until we find our specific message (the service may emit its own
    -- startup trace first).
    local received
    for _ = 1, 5 do
        local msg = perform(op.choice(
            log_sub:recv_op(),
            sleep.sleep_op(1):wrap(function() return nil end)
        ))
        if not msg then break end
        if msg.payload and msg.payload.message and
           msg.payload.message:find('lifecycle publish test', 1, true) then
            received = msg
            break
        end
    end

    stop_scope(svc_scope)

    luaunit.assertNotNil(received, 'expected log entry to be published by running service')
    luaunit.assertEquals(received.topic[2], 'info')
    luaunit.assertStrContains(received.payload.message, 'lifecycle publish test')
end

-- After the service scope is cancelled, _conn must be cleared so subsequent
-- log calls are not published.
function TestLogServiceLifecycle:test_conn_cleared_after_stop()
    local root = fibers.current_scope()
    local bus  = make_bus()
    local conn = bus:connect()

    local status_sub = conn:subscribe({ 'svc', 'log', 'status' })
    local svc_scope  = start_log(bus, root)

    -- Wait until running.
    while true do
        local smsg = perform(op.choice(
            status_sub:recv_op(),
            sleep.sleep_op(1):wrap(function() return nil end)
        ))
        if not smsg then break end
        if smsg.payload and smsg.payload.state == 'running' then break end
    end

    stop_scope(svc_scope)

    -- After stop the singleton's _conn must be nil.
    local log = require 'services.log'
    luaunit.assertNil(log._conn, '_conn must be nil after service stops')
end

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

if is_entry_point then
    fibers.run(function()
        os.exit(luaunit.LuaUnit.run())
    end)
end
