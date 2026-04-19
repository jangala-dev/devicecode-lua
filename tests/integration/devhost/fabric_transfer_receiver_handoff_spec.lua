
local busmod     = require 'bus'
local duplex     = require 'tests.support.duplex_stream'
local probe      = require 'tests.support.bus_probe'
local runfibers  = require 'tests.support.run_fibers'
local safe       = require 'coxpcall'
local mailbox    = require 'fibers.mailbox'

local session    = require 'services.fabric.session'

local T = {}

local function make_svc(conn)
    return {
        conn = conn,
        now = function() return require('fibers').now() end,
        wall = function() return 'now' end,
        obs_log = function() end,
        obs_event = function() end,
        obs_state = function() end,
        status = function() end,
    }
end

local function wait_ready(conn, link_id, timeout)
    return probe.wait_until(function()
        local ok, payload = safe.pcall(function()
            return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id, 'session' }, { timeout = 0.02 })
        end)
        return ok and type(payload) == 'table'
            and type(payload.status) == 'table'
            and payload.status.ready == true
    end, { timeout = timeout or 1.5, interval = 0.01 })
end

local function bind_reply_loop(scope, ep, handler)
    local ok, err = scope:spawn(function()
        while true do
            local req, rerr = ep:recv()
            if not req then return end
            local reply, ferr = handler(req.payload or {}, req)
            if reply == nil then
                if ferr == '__forwarded__' then
                    -- transfer manager will answer later using the original request
                else
                    req:fail(ferr or 'failed')
                end
            else
                req:reply(reply)
            end
        end
    end)
    assert(ok, tostring(err))
end

local function spawn_transfer_endpoint(scope, conn, topic, transfer_ctl_tx)
    local ep = conn:bind(topic, { queue_len = 16 })
    bind_reply_loop(scope, ep, function(payload, req)
        local ok, reason = transfer_ctl_tx:send(req)
        if ok ~= true then
            return nil, reason or 'queue_closed'
        end
        return nil, '__forwarded__'
    end)
end

function T.devhost_fabric_transfer_hands_off_to_local_receiver_before_ack()
    runfibers.run(function(scope)
        local bus = busmod.new()
        local caller = bus:connect()

        local a_stream, b_stream = duplex.new_pair()
        local a_ctl_tx, a_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
        local b_ctl_tx, b_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
        local a_report_tx, a_report_rx = mailbox.new(8, { full = 'reject_newest' })
        local b_report_tx, b_report_rx = mailbox.new(8, { full = 'reject_newest' })

        local received = {}
        local receiver_conn = bus:connect()
        local receiver_ep = receiver_conn:bind({ 'cmd', 'blob', 'ingest' }, { queue_len = 16 })
        bind_reply_loop(scope, receiver_ep, function(payload)
            received[#received + 1] = payload
            return { ok = true, accepted = true }
        end)

        local ok1, err1 = scope:spawn(function()
            session.run({
                svc = make_svc(bus:connect()),
                conn = bus:connect(),
                link_id = 'link-a',
                transfer_ctl_rx = a_ctl_rx,
                report_tx = a_report_tx,
                cfg = {
                    node_id = 'node-a',
                    member_class = 'cm5',
                    link_class = 'member_uart',
                    transport = { open = function() return a_stream end },
                },
            })
        end)
        assert(ok1, tostring(err1))

        local ok2, err2 = scope:spawn(function()
            session.run({
                svc = make_svc(bus:connect()),
                conn = bus:connect(),
                link_id = 'link-b',
                transfer_ctl_rx = b_ctl_rx,
                report_tx = b_report_tx,
                cfg = {
                    node_id = 'node-b',
                    member_class = 'mcu',
                    link_class = 'member_uart',
                    transport = { open = function() return b_stream end },
                },
            })
        end)
        assert(ok2, tostring(err2))

        spawn_transfer_endpoint(scope, bus:connect(), { 'cmd', 'xfer', 'link-a' }, a_ctl_tx)

        assert(wait_ready(caller, 'link-a', 2.0) == true)
        assert(wait_ready(caller, 'link-b', 2.0) == true)

        local transfer_sub = caller:subscribe({ 'state', 'fabric', 'link', 'link-b', 'transfer' }, { queue_len = 8, full = 'drop_oldest' })

        local reply, err = caller:call({ 'cmd', 'xfer', 'link-a' }, {
            op = 'send_blob',
            link_id = 'link-a',
            source = 'firmware-bytes',
            receiver = { 'cmd', 'blob', 'ingest' },
            meta = { kind = 'firmware', version = 'mcu-v9' },
        }, { timeout = 1.0 })

        assert(err == nil)
        assert(type(reply) == 'table')
        assert(reply.ok == true)

        assert(#received == 1)
        local payload = received[1]
        assert(payload.data == 'firmware-bytes')
        assert(payload.size == #'firmware-bytes')
        assert(type(payload.meta) == 'table')
        assert(payload.meta.kind == 'firmware')
        assert(payload.meta.version == 'mcu-v9')

        local retained
        while true do
            local msg, rerr = transfer_sub:recv()
            assert(msg ~= nil, tostring(rerr))
            if type(msg.payload) == 'table' and type(msg.payload.status) == 'table' and msg.payload.status.state == 'done' then
                retained = msg.payload
                break
            end
        end
        transfer_sub:unsubscribe()
        assert(retained.kind == 'fabric.link.transfer')
        assert(type(retained.status) == 'table')
        assert(retained.status.state == 'done')
        assert(retained.status.direction == 'in')
    end, { timeout = 3.0 })
end

function T.devhost_fabric_transfer_receiver_failure_aborts_sender_request()
    runfibers.run(function(scope)
        local bus = busmod.new()
        local caller = bus:connect()

        local a_stream, b_stream = duplex.new_pair()
        local a_ctl_tx, a_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
        local b_ctl_tx, b_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
        local a_report_tx, a_report_rx = mailbox.new(8, { full = 'reject_newest' })
        local b_report_tx, b_report_rx = mailbox.new(8, { full = 'reject_newest' })

        local receiver_conn = bus:connect()
        local receiver_ep = receiver_conn:bind({ 'cmd', 'blob', 'reject' }, { queue_len = 16 })
        bind_reply_loop(scope, receiver_ep, function(payload)
            return nil, 'ingest_rejected'
        end)

        local ok1, err1 = scope:spawn(function()
            session.run({
                svc = make_svc(bus:connect()),
                conn = bus:connect(),
                link_id = 'link-a',
                transfer_ctl_rx = a_ctl_rx,
                report_tx = a_report_tx,
                cfg = {
                    node_id = 'node-a',
                    member_class = 'cm5',
                    link_class = 'member_uart',
                    transport = { open = function() return a_stream end },
                },
            })
        end)
        assert(ok1, tostring(err1))

        local ok2, err2 = scope:spawn(function()
            session.run({
                svc = make_svc(bus:connect()),
                conn = bus:connect(),
                link_id = 'link-b',
                transfer_ctl_rx = b_ctl_rx,
                report_tx = b_report_tx,
                cfg = {
                    node_id = 'node-b',
                    member_class = 'mcu',
                    link_class = 'member_uart',
                    transport = { open = function() return b_stream end },
                },
            })
        end)
        assert(ok2, tostring(err2))

        spawn_transfer_endpoint(scope, bus:connect(), { 'cmd', 'xfer', 'link-a' }, a_ctl_tx)

        assert(wait_ready(caller, 'link-a', 2.0) == true)
        assert(wait_ready(caller, 'link-b', 2.0) == true)

        local transfer_sub = caller:subscribe({ 'state', 'fabric', 'link', 'link-b', 'transfer' }, { queue_len = 8, full = 'drop_oldest' })

        local reply, err = caller:call({ 'cmd', 'xfer', 'link-a' }, {
            op = 'send_blob',
            link_id = 'link-a',
            source = 'firmware-bytes',
            receiver = { 'cmd', 'blob', 'reject' },
            meta = { kind = 'firmware' },
        }, { timeout = 1.0 })

        assert(reply == nil)
        assert(type(err) == 'string')
        assert(err:match('ingest_rejected') ~= nil)
    end, { timeout = 3.0 })
end

return T
