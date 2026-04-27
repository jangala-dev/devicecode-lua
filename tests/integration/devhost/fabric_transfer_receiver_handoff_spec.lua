
local busmod     = require 'bus'
local duplex     = require 'tests.support.duplex_stream'
local probe      = require 'tests.support.bus_probe'
local runfibers  = require 'tests.support.run_fibers'
local safe       = require 'coxpcall'
local mailbox    = require 'fibers.mailbox'
local test_diag  = require 'tests.support.test_diag'

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
	local payload = probe.wait_fabric_link_ready(conn, link_id, { timeout = timeout or 2.0 })
	return type(payload) == 'table'
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
        local diag = test_diag.for_stack(scope, bus, { fabric = true, max_records = 360 })
        test_diag.add_subsystem(diag, 'fabric', {
            service_fn = test_diag.retained_fn(caller, { 'svc', 'fabric', 'status' }),
            summary_fn = test_diag.retained_fn(caller, { 'state', 'fabric' }),
            session_fn = test_diag.retained_fn(caller, { 'state', 'fabric', 'link', 'link-a', 'session' }),
            transfer_fn = test_diag.retained_fn(caller, { 'state', 'fabric', 'link', 'link-a', 'transfer' }),
        })

        local a_stream, b_stream = duplex.new_pair()
        local a_ctl_tx, a_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
        local b_ctl_tx, b_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
        local a_report_tx, a_report_rx = mailbox.new(8, { full = 'reject_newest' })
        local b_report_tx, b_report_rx = mailbox.new(8, { full = 'reject_newest' })

        local received = {}
        local receiver_conn = bus:connect()
        local receiver_ep = receiver_conn:bind({ 'cmd', 'blob', 'ingest' }, { queue_len = 16 })
        bind_reply_loop(scope, receiver_ep, function(payload)
            local artefact = payload.artefact
            assert(type(artefact) == 'table')
            local src = artefact:open_source()
            local data = assert(src:read_chunk(0, payload.size + 16))
            received[#received + 1] = {
                link_id = payload.link_id,
                xfer_id = payload.xfer_id,
                size = payload.size,
                checksum = payload.checksum,
                meta = payload.meta,
                artefact = artefact,
                data = data,
            }
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

        if not wait_ready(caller, 'link-a', 2.0) then diag:fail('expected link-a to reach ready') end
        if not wait_ready(caller, 'link-b', 2.0) then diag:fail('expected link-b to reach ready') end

        local reply, err = caller:call({ 'cmd', 'xfer', 'link-a' }, {
            op = 'send_blob',
            link_id = 'link-a',
            source = 'firmware-bytes',
            receiver = { 'cmd', 'blob', 'ingest' },
            meta = { kind = 'firmware', image_id = 'mcu-image-9' },
        }, { timeout = 1.0 })

        if err ~= nil or type(reply) ~= 'table' or reply.ok ~= true then
            diag:fail('expected successful fabric transfer reply, got error=' .. tostring(err))
        end

        if #received ~= 1 then diag:fail('expected receiver handoff to run exactly once') end
        local payload = received[1]
        if type(payload.artefact) ~= 'table'
            or payload.data ~= 'firmware-bytes'
            or payload.artefact:checksum() ~= payload.checksum
            or payload.size ~= #'firmware-bytes'
            or type(payload.meta) ~= 'table'
            or payload.meta.kind ~= 'firmware'
            or payload.meta.image_id ~= 'mcu-image-9'
        then
            diag:fail('unexpected receiver handoff payload')
        end

        local retained = probe.wait_fabric_link_component(caller, 'link-b', 'transfer', function(payload)
            return type(payload.status) == 'table' and payload.status.state == 'done'
        end, { timeout = 1.0, describe = function() return diag:render() end })
        if retained.kind ~= 'fabric.link.transfer'
            or type(retained.status) ~= 'table'
            or retained.status.state ~= 'done'
            or retained.status.direction ~= 'in'
        then
            diag:fail('expected retained inbound transfer state to be done')
        end
    end, { timeout = 3.0 })
end

function T.devhost_fabric_transfer_receiver_failure_aborts_sender_request()
    runfibers.run(function(scope)
        local bus = busmod.new()
        local caller = bus:connect()
        local diag = test_diag.for_stack(scope, bus, { fabric = true, max_records = 360 })
        test_diag.add_subsystem(diag, 'fabric', {
            service_fn = test_diag.retained_fn(caller, { 'svc', 'fabric', 'status' }),
            summary_fn = test_diag.retained_fn(caller, { 'state', 'fabric' }),
            session_fn = test_diag.retained_fn(caller, { 'state', 'fabric', 'link', 'link-a', 'session' }),
            transfer_fn = test_diag.retained_fn(caller, { 'state', 'fabric', 'link', 'link-a', 'transfer' }),
        })

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

        if not wait_ready(caller, 'link-a', 2.0) then diag:fail('expected link-a to reach ready') end
        if not wait_ready(caller, 'link-b', 2.0) then diag:fail('expected link-b to reach ready') end

        local reply, err = caller:call({ 'cmd', 'xfer', 'link-a' }, {
            op = 'send_blob',
            link_id = 'link-a',
            source = 'firmware-bytes',
            receiver = { 'cmd', 'blob', 'reject' },
            meta = { kind = 'firmware' },
        }, { timeout = 1.0 })

        if not (reply == nil and type(err) == 'string' and err:match('ingest_rejected') ~= nil) then
            diag:fail('expected receiver rejection to abort sender request')
        end
    end, { timeout = 3.0 })
end

return T
