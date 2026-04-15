-- services/fabric/session.lua
--
-- One fabric session per configured link.

local fibers   = require 'fibers'
local sleep    = require 'fibers.sleep'
local mailbox  = require 'fibers.mailbox'
local safe     = require 'coxpcall'
local authz    = require 'devicecode.authz'

local protocol = require 'services.fabric.protocol'
local topicmap = require 'services.fabric.topicmap'
local uart_tx  = require 'services.fabric.transport_uart'
local transfer = require 'services.fabric.transfer'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local M = {}

local function topic_s(t)
    return table.concat(t or {}, '/')
end

local function line_preview(line, tail)
    if type(line) ~= 'string' then
        return nil
    end
    local max = 120
    if #line > max then
        line = tail and line:sub(-max) or line:sub(1, max)
    end
    return string.format('%q', line)
end

local function publish_link_state(conn, svc, link_id, fields)
    local payload = { link_id = link_id, t = svc:now() }
    for k, v in pairs(fields or {}) do payload[k] = v end
    conn:retain({ 'state', 'fabric', 'link', link_id }, payload)
end

local function choose_transport(conn, svc, link_id, link_cfg)
    local k = (((link_cfg.transport or {}).kind) or 'uart')
    if k == 'uart' then
        local cfg = {}
        for key, value in pairs(link_cfg.transport or {}) do
            cfg[key] = value
        end
        cfg.link_id = link_id
        return uart_tx.new(conn, svc, cfg), nil
    end
    return nil, 'unsupported transport kind ' .. tostring(k)
end

local function keepalive_cfg(link_cfg)
    local ka = (type(link_cfg.keepalive) == 'table') and link_cfg.keepalive or {}
    return {
        hello_retry_s = (type(ka.hello_retry_s) == 'number') and ka.hello_retry_s or 10.0,
        idle_ping_s   = (type(ka.idle_ping_s)   == 'number') and ka.idle_ping_s   or 15.0,
        stale_after_s = (type(ka.stale_after_s) == 'number') and ka.stale_after_s or 45.0,
    }
end

local function new_pending_store()
    local by_id = {}
    local store = {}

    function store:open(id)
        local tx, rx = mailbox.new(1, { full = 'reject_newest' })
        by_id[id] = { tx = tx, rx = rx }
        return rx
    end

    function store:deliver(id, msg)
        local rec = by_id[id]
        if not rec then return false end
        rec.tx:send(msg)
        rec.tx:close('done')
        by_id[id] = nil
        return true
    end

    function store:close(id, reason)
        local rec = by_id[id]
        if not rec then return false end
        rec.tx:close(reason or 'closed')
        by_id[id] = nil
        return true
    end

    function store:close_all(reason)
        for id, rec in pairs(by_id) do
            rec.tx:close(reason or 'closed')
            by_id[id] = nil
        end
    end

    return store
end

local function start_export_publishers(conn, svc, link_id, export_cfg, send_frame, mark_ready)
    for i = 1, #(export_cfg.publish or {}) do
        local rule = export_cfg.publish[i]

        fibers.spawn(function()
            local sub = conn:subscribe(rule.local_topic, {
                queue_len = rule.queue_len or 50,
                full      = 'drop_oldest',
            })

            mark_ready('export')

            svc:obs_log('info', {
                what     = 'export_publish_started',
                link_id  = link_id,
                local_t  = topic_s(rule.local_topic),
                remote_t = topic_s(rule.remote_topic),
            })

            while true do
                local msg, err = perform(sub:recv_op())
                if not msg then
                    svc:obs_log('warn', {
                        what    = 'export_publish_stopped',
                        link_id = link_id,
                        err     = tostring(err),
                    })
                    return
                end

                local remote_topic = topicmap.apply_first({ rule }, msg.topic, 'local_topic', 'remote_topic')
                if remote_topic then
                    local ok, serr = send_frame(protocol.pub(remote_topic, msg.payload, rule.retain))
                    if ok ~= true then
                        svc:obs_log('warn', {
                            what    = 'export_send_failed',
                            link_id = link_id,
                            err     = tostring(serr),
                        })
                    end
                end
            end
        end)
    end
end

local function start_export_retained_watchers(conn, svc, link_id, export_cfg, send_frame, mark_ready)
    for i = 1, #(export_cfg.publish or {}) do
        local rule = export_cfg.publish[i]

        if rule.retain == true then
            fibers.spawn(function()
                local rw = conn:watch_retained(rule.local_topic, {
                    queue_len = rule.queue_len or 50,
                    full      = 'drop_oldest',
                    replay    = true,
                })

                mark_ready('retained')

                svc:obs_log('info', {
                    what     = 'export_retained_started',
                    link_id  = link_id,
                    local_t  = topic_s(rule.local_topic),
                    remote_t = topic_s(rule.remote_topic),
                })

                while true do
                    local ev, err = perform(rw:recv_op())
                    if not ev then
                        svc:obs_log('warn', {
                            what    = 'export_retained_stopped',
                            link_id = link_id,
                            err     = tostring(err),
                        })
                        return
                    end

                    local remote_topic = topicmap.apply_first({ rule }, ev.topic, 'local_topic', 'remote_topic')
                    if remote_topic then
                        local ok, serr
                        if ev.op == 'retain' then
                            ok, serr = send_frame(protocol.pub(remote_topic, ev.payload, true))
                        elseif ev.op == 'unretain' then
                            ok, serr = send_frame(protocol.unretain(remote_topic))
                        end
                        if ok ~= true then
                            svc:obs_log('warn', {
                                what    = 'export_retained_send_failed',
                                link_id = link_id,
                                err     = tostring(serr),
                            })
                        end
                    end
                end
            end)
        end
    end
end

local function remote_call(pending, send_frame, remote_topic, payload, timeout_s)
    local id = protocol.next_id()
    local rx = pending:open(id)

    local ok, serr = send_frame(protocol.call(id, remote_topic, payload, math.floor((timeout_s or 5.0) * 1000)))
    if ok ~= true then
        pending:close(id, 'send_failed')
        return nil, tostring(serr)
    end

    local which, a = perform(named_choice {
        reply = rx:recv_op(),
        timer = sleep.sleep_op(timeout_s or 5.0):wrap(function() return true end),
    })

    if which == 'timer' then
        pending:close(id, 'timeout')
        return nil, 'timeout'
    end

    local msg = a
    if type(msg) ~= 'table' or msg.t ~= 'reply' then
        return nil, 'invalid reply'
    end
    if msg.ok == true then
        return msg.payload, nil
    end
    return nil, tostring(msg.err or 'remote error')
end

local function start_proxy_call_endpoints(conn, svc, link_id, proxy_rules, pending, send_frame, mark_ready)
    for i = 1, #(proxy_rules or {}) do
        local rule = proxy_rules[i]
        fibers.spawn(function()
            local ep = conn:bind(rule.local_topic, { queue_len = rule.queue_len or 8 })

            mark_ready('proxy')

            svc:obs_log('info', {
                what     = 'proxy_call_started',
                link_id  = link_id,
                local_t  = topic_s(rule.local_topic),
                remote_t = topic_s(rule.remote_topic),
            })

            while true do
                local msg, err = perform(ep:recv_op())
                if not msg then
                    svc:obs_log('warn', {
                        what    = 'proxy_call_stopped',
                        link_id = link_id,
                        err     = tostring(err),
                    })
                    return
                end

                local payload, cerr = remote_call(pending, send_frame, rule.remote_topic, msg.payload, rule.timeout_s or 5.0)
                if msg.reply_to ~= nil then
                    if payload ~= nil then
                        conn:publish_one(msg.reply_to, payload, { id = msg.id })
                    else
                        conn:publish_one(msg.reply_to, { ok = false, err = tostring(cerr) }, { id = msg.id })
                    end
                end
            end
        end)
    end
end

local function handle_incoming_pub(peer_conn, link_cfg, msg)
    local local_topic = topicmap.apply_first(link_cfg.import.publish, msg.topic, 'remote_topic', 'local_topic')
    if not local_topic then
        return false, 'no import rule'
    end
    if msg.retain then
        peer_conn:retain(local_topic, msg.payload)
    else
        peer_conn:publish(local_topic, msg.payload)
    end
    return true, nil
end

local function handle_incoming_unretain(peer_conn, link_cfg, msg)
    local local_topic = topicmap.apply_first(link_cfg.import.publish, msg.topic, 'remote_topic', 'local_topic')
    if not local_topic then
        return false, 'no import rule'
    end
    peer_conn:unretain(local_topic)
    return true, nil
end

local function handle_incoming_call(peer_conn, send_frame, link_cfg, msg)
    local local_topic = topicmap.apply_first(link_cfg.import.call, msg.topic, 'remote_topic', 'local_topic')
    if not local_topic then
        return send_frame(protocol.reply_err(msg.id, 'no_route'))
    end

    local payload, err = peer_conn:call(local_topic, msg.payload, {
        timeout = (type(msg.timeout_ms) == 'number' and msg.timeout_ms > 0) and (msg.timeout_ms / 1000.0) or 5.0,
    })

    if payload ~= nil then
        return send_frame(protocol.reply_ok(msg.id, payload))
    else
        return send_frame(protocol.reply_err(msg.id, err or 'call failed'))
    end
end

local function reply_control(job, payload)
    local tx = job and job.reply_tx
    if tx then
        tx:send(payload)
        tx:close('done')
    end
end

function M.run(conn, svc, opts)
    local link_id    = assert(opts.link_id, 'fabric session requires link_id')
    local link_cfg   = assert(opts.link, 'fabric session requires link cfg')
    local peer_id    = assert(link_cfg.peer_id, 'fabric session requires peer_id')
    local connect    = assert(opts.connect, 'fabric session requires connect(principal)')
    local control_rx = opts.control_rx

    local peer_conn = connect(authz.peer_principal(peer_id, { roles = { 'admin' } }))
    local pending   = new_pending_store()
    local transport, terr = choose_transport(conn, svc, link_id, link_cfg)
    if not transport then
        publish_link_state(conn, svc, link_id, {
            status  = 'down',
            ready   = false,
            peer_id = peer_id,
            err     = tostring(terr),
        })
        error(('fabric/%s: transport setup failed: %s'):format(link_id, tostring(terr)), 0)
    end
    local ka        = keepalive_cfg(link_cfg)

    local state = {
        node_id       = opts.node_id or os.getenv('DEVICECODE_NODE_ID') or 'devicecode',
        local_sid     = protocol.next_id(),
        peer_id       = peer_id,
        peer_node     = nil,
        peer_sid      = nil,
        established   = false,
        last_rx_at    = nil,
        last_tx_at    = nil,
        last_hello_at = nil,
        last_pong_at  = nil,
    }

    local retained_rules = 0
    for i = 1, #(link_cfg.export.publish or {}) do
        if link_cfg.export.publish[i].retain == true then
            retained_rules = retained_rules + 1
        end
    end

    local readiness = {
        expected       = #(link_cfg.export.publish or {}) + retained_rules + #(link_cfg.proxy_calls or {}),
        started        = 0,
        export_ready   = 0,
        retained_ready = 0,
        proxy_ready    = 0,
    }

    local function is_ready()
        return readiness.started >= readiness.expected
    end

    local function current_status()
        if state.established and is_ready() then return 'ready' end
        if state.established then return 'session_up' end
        return 'opening'
    end

    local function publish_session(extra)
        extra = extra or {}

        local payload = {
            status         = extra.status or current_status(),
            ready          = state.established and is_ready() or false,
            established    = state.established,
            peer_id        = peer_id,
            local_sid      = state.local_sid,
            peer_sid       = state.peer_sid,
            remote_id      = state.peer_node,
            kind           = ((link_cfg.transport or {}).kind) or 'uart',
            last_rx_at     = state.last_rx_at,
            last_tx_at     = state.last_tx_at,
            last_pong_at   = state.last_pong_at,
            export_ready   = readiness.export_ready,
            retained_ready = readiness.retained_ready,
            proxy_ready    = readiness.proxy_ready,
            expected       = readiness.expected,
        }

        if extra.err ~= nil then payload.err = extra.err end
        if extra.reason ~= nil then payload.reason = extra.reason end

        publish_link_state(conn, svc, link_id, payload)
    end

    local function mark_worker_ready(kind)
        readiness.started = readiness.started + 1
        if kind == 'export' then
            readiness.export_ready = readiness.export_ready + 1
        elseif kind == 'retained' then
            readiness.retained_ready = readiness.retained_ready + 1
        elseif kind == 'proxy' then
            readiness.proxy_ready = readiness.proxy_ready + 1
        end
        publish_session()
    end

    local bad_frames = {
        count        = 0,
        window_start = nil,
        threshold    = 5,
        window_s     = 30.0,
    }

    local function reset_bad_frames()
        bad_frames.count = 0
        bad_frames.window_start = nil
    end

    local xfer

    local function note_bad_frame(what, detail, raw_t, line)
        local tnow = svc:now()
        if bad_frames.window_start == nil or (tnow - bad_frames.window_start) > bad_frames.window_s then
            bad_frames.window_start = tnow
            bad_frames.count = 0
        end
        bad_frames.count = bad_frames.count + 1

        svc:obs_log('warn', {
            what      = what,
            link_id   = link_id,
            err       = tostring(detail),
            t         = raw_t,
            n         = bad_frames.count,
            line_len  = type(line) == 'string' and #line or nil,
            line_head = line_preview(line, false),
            line_tail = line_preview(line, true),
        })

        if bad_frames.count >= bad_frames.threshold then
            pending:close_all('too_many_bad_frames')
            if xfer then safe.pcall(function() xfer:abort_all('too_many_bad_frames') end) end
            publish_link_state(conn, svc, link_id, {
                status      = 'down',
                ready       = false,
                established = state.established,
                peer_id     = peer_id,
                local_sid   = state.local_sid,
                peer_sid    = state.peer_sid,
                remote_id   = state.peer_node,
                kind        = ((link_cfg.transport or {}).kind) or 'uart',
                err         = 'too_many_bad_frames',
            })
            error(('fabric/%s: too many bad frames'):format(link_id), 0)
        end
    end

    local function validate_peer_hello(msg)
        if msg.peer ~= state.node_id then
            return nil, ('unexpected hello.peer: %s'):format(tostring(msg.peer))
        end
        if msg.node ~= peer_id then
            return nil, ('unexpected hello.node: %s'):format(tostring(msg.node))
        end
        if msg.proto ~= protocol.PROTO_VERSION then
            return nil, ('unsupported proto: %s'):format(tostring(msg.proto))
        end
        return true
    end

    local function validate_peer_ack(msg)
        if msg.node ~= peer_id then
            return nil, ('unexpected hello_ack.node: %s'):format(tostring(msg.node))
        end
        if msg.proto ~= protocol.PROTO_VERSION then
            return nil, ('unsupported proto: %s'):format(tostring(msg.proto))
        end
        return true
    end

    local function send_frame(msg)
        local ok, err = perform(transport:send_msg_op(msg))
        if ok == true then
            local tnow = svc:now()
            state.last_tx_at = tnow
            if msg.t == 'hello' then
                state.last_hello_at = tnow
            end
            return true, nil
        end
        return nil, err
    end

    local function mark_rx(msg)
        local tnow = svc:now()
        state.last_rx_at = tnow
        if msg.t == 'pong' then
            state.last_pong_at = tnow
        end
    end

    local function note_peer_identity(msg)
        local sid_changed = (state.peer_sid ~= nil and msg.sid ~= nil and state.peer_sid ~= msg.sid)

        if msg.node ~= nil then state.peer_node = msg.node end
        if msg.sid  ~= nil then state.peer_sid  = msg.sid  end

        state.established = true

        if sid_changed then
            pending:close_all('peer_session_changed')
            if xfer then safe.pcall(function() xfer:abort_all('peer_session_changed') end) end
            svc:obs_event('peer_session_changed', {
                link_id  = link_id,
                peer_id  = peer_id,
                peer_sid = state.peer_sid,
                node     = state.peer_node,
            })
        end

        reset_bad_frames()
        publish_session()
    end

    local function note_peer_sid_only(msg)
        if type(msg.sid) ~= 'string' or msg.sid == '' then
            return
        end

        local sid_changed = (state.peer_sid ~= nil and state.peer_sid ~= msg.sid)
        state.peer_sid = msg.sid

        if sid_changed then
            pending:close_all('peer_session_changed')
            if xfer then safe.pcall(function() xfer:abort_all('peer_session_changed') end) end
            svc:obs_event('peer_session_changed', {
                link_id  = link_id,
                peer_id  = peer_id,
                peer_sid = state.peer_sid,
                node     = state.peer_node,
            })
        end

        publish_session()
    end

    local function expect_peer_reconnect(reason, extra)
        if state.established ~= true then
            return
        end

        reason = tostring(reason or 'peer_reboot_expected')
        extra = type(extra) == 'table' and extra or {}

        pending:close_all(reason)

        state.established = false
        state.peer_node = nil
        state.peer_sid = nil
        state.last_rx_at = nil
        state.last_tx_at = nil
        state.last_hello_at = nil
        state.last_pong_at = nil

        svc:obs_log('info', {
            what        = 'peer_reconnect_expected',
            link_id     = link_id,
            peer_id     = peer_id,
            reason      = reason,
            transfer_id = extra.transfer_id,
            kind        = extra.kind,
        })
        publish_session({ status = 'opening', reason = reason })

        fibers.spawn(function()
            perform(sleep.sleep_op(ka.hello_retry_s))
            if state.established then
                return
            end

            local ok2, err2 = send_frame(protocol.hello(state.node_id, peer_id, {
                pub           = true,
                call          = true,
                blob_transfer = true,
            }, { sid = state.local_sid }))
            if ok2 ~= true then
                svc:obs_log('warn', {
                    what    = 'hello_reconnect_failed',
                    link_id = link_id,
                    err     = tostring(err2),
                })
            end
        end)
    end

    local function next_deadline(tnow)
        local best = math.huge
        if not state.established then
            local hello_due = (state.last_hello_at and (state.last_hello_at + ka.hello_retry_s)) or tnow
            if hello_due < best then best = hello_due end
        end
        -- Schedule the outbound keepalive ping from last_tx_at only.
        -- Mixing in last_rx_at would let a chatty peer (e.g. the MCU
        -- emitting ~1 pub/sec) perpetually reset our ping timer, so we
        -- would never send anything on the wire. The peer's own stale
        -- timer then fires on its side because it has not seen any
        -- traffic from us for stale_after_s. The inbound-side stale
        -- check below still correctly uses last_rx_at.
        if state.last_tx_at ~= nil then
            local ping_due = state.last_tx_at + ka.idle_ping_s
            if ping_due < best then best = ping_due end
        end
        if state.last_rx_at ~= nil then
            local stale_due = state.last_rx_at + ka.stale_after_s
            if stale_due < best then best = stale_due end
        end
        return best
    end

    local scope = fibers.current_scope()
    scope:finally(function()
        pending:close_all('session_end')
        if xfer then safe.pcall(function() xfer:abort_all('session_end') end) end
        safe.pcall(function() transport:close() end)
    end)

    local ok, err = transport:open()
    if ok ~= true then
        publish_link_state(conn, svc, link_id, {
            status  = 'down',
            ready   = false,
            peer_id = peer_id,
            err     = tostring(err),
        })
        error(('fabric/%s: transport open failed: %s'):format(link_id, tostring(err)), 0)
    end

    xfer = transfer.new({
        svc           = svc,
        conn          = conn,
        link_id       = link_id,
        peer_id       = peer_id,
        send_frame    = send_frame,
        sink_factory  = opts.sink_factory,
        chunk_raw     = (((link_cfg.transfer or {}).chunk_raw) or 768),
        ack_timeout_s = (((link_cfg.transfer or {}).ack_timeout_s) or 2.0),
        max_retries   = (((link_cfg.transfer or {}).max_retries) or 5),
        on_state_update = function(payload)
            if type(payload) ~= 'table' then
                return
            end
            if payload.dir ~= 'out' or payload.status ~= 'done' then
                return
            end
            if type(payload.kind) ~= 'string' or payload.kind:match('^firmware%.') == nil then
                return
            end

            expect_peer_reconnect('peer_reboot_expected', {
                transfer_id = payload.id,
                kind        = payload.kind,
            })
        end,
    })

    publish_session({ status = 'opening' })

    svc:obs_log('info', {
        what    = 'link_up',
        link_id = link_id,
        peer_id = peer_id,
    })

    local hello_ok, hello_err = send_frame(protocol.hello(state.node_id, peer_id, {
        pub           = true,
        call          = true,
        blob_transfer = true,
    }, { sid = state.local_sid }))
    if hello_ok ~= true then
        svc:obs_log('warn', { what = 'hello_send_failed', link_id = link_id, err = tostring(hello_err) })
    end

    start_export_publishers(conn, svc, link_id, link_cfg.export, send_frame, mark_worker_ready)
    start_export_retained_watchers(conn, svc, link_id, link_cfg.export, send_frame, mark_worker_ready)
    start_proxy_call_endpoints(conn, svc, link_id, link_cfg.proxy_calls, pending, send_frame, mark_worker_ready)

    local function handle_control(job)
        if type(job) ~= 'table' then return end

        if job.op == 'send_blob' then
            if not state.established then
                reply_control(job, { ok = false, err = 'session_not_established' })
                return
            end
            if not is_ready() then
                reply_control(job, { ok = false, err = 'session_not_ready' })
                return
            end

            local transfer_id, xerr = xfer:start_send(job.source, job.meta or {})
            if transfer_id then
                reply_control(job, { ok = true, transfer_id = transfer_id })
            else
                reply_control(job, { ok = false, err = tostring(xerr) })
            end

        elseif job.op == 'transfer_status' then
            local st, serr = xfer:status(job.transfer_id)
            if st then
                reply_control(job, { ok = true, transfer = st })
            else
                reply_control(job, { ok = false, err = tostring(serr) })
            end

        elseif job.op == 'transfer_abort' then
            local ok2, aerr = xfer:abort(job.transfer_id, job.reason or 'aborted')
            reply_control(job, { ok = (ok2 == true), err = (ok2 ~= true) and tostring(aerr) or nil })
        else
            reply_control(job, { ok = false, err = 'unknown control op: ' .. tostring(job.op) })
        end
    end

    while true do
        local tnow = svc:now()
        local deadline = next_deadline(tnow)

        local arms = { recv = transport:recv_line_op() }
        if control_rx then arms.ctrl = control_rx:recv_op() end
        if deadline < math.huge then
            local dt = deadline - tnow
            if dt < 0 then dt = 0 end
            arms.timer = sleep.sleep_op(dt):wrap(function() return true end)
        end

        local which, a, b = perform(named_choice(arms))

        if which == 'ctrl' then
            local job = a
            if job == nil then
                control_rx = nil
            else
                handle_control(job)
            end

        elseif which == 'timer' then
            local now2 = svc:now()

            if state.last_rx_at ~= nil and (now2 - state.last_rx_at) >= ka.stale_after_s then
                pending:close_all('peer_stale')
                if xfer then safe.pcall(function() xfer:abort_all('peer_stale') end) end
                publish_link_state(conn, svc, link_id, {
                    status      = 'down',
                    ready       = false,
                    established = state.established,
                    peer_id     = peer_id,
                    local_sid   = state.local_sid,
                    peer_sid    = state.peer_sid,
                    remote_id   = state.peer_node,
                    kind        = ((link_cfg.transport or {}).kind) or 'uart',
                    err         = 'peer_stale',
                })
                error(('fabric/%s: peer stale'):format(link_id), 0)
            end

            if not state.established then
                local ok2, err2 = send_frame(protocol.hello(state.node_id, peer_id, {
                    pub           = true,
                    call          = true,
                    blob_transfer = true,
                }, { sid = state.local_sid }))
                if ok2 ~= true then
                    svc:obs_log('warn', { what = 'hello_retry_failed', link_id = link_id, err = tostring(err2) })
                end
            else
                if state.last_tx_at ~= nil and (now2 - state.last_tx_at) >= ka.idle_ping_s then
                    local ok2, err2 = send_frame(protocol.ping({ sid = state.local_sid }))
                    if ok2 ~= true then
                        svc:obs_log('warn', { what = 'ping_send_failed', link_id = link_id, err = tostring(err2) })
                    end
                end
            end

        else
            local line, rerr = a, b
            if not line then
                pending:close_all('transport_down')
                if xfer then safe.pcall(function() xfer:abort_all('transport_down') end) end
                publish_link_state(conn, svc, link_id, {
                    status      = 'down',
                    ready       = false,
                    established = state.established,
                    peer_id     = peer_id,
                    local_sid   = state.local_sid,
                    peer_sid    = state.peer_sid,
                    remote_id   = state.peer_node,
                    kind        = ((link_cfg.transport or {}).kind) or 'uart',
                    err         = tostring(rerr),
                })
                error(('fabric/%s: receive failed: %s'):format(link_id, tostring(rerr)), 0)
            end

            local raw, derr = protocol.decode_line(line)
            if not raw then
                note_bad_frame('decode_failed', derr, nil, line)
            else
                local msg, verr = protocol.validate_message(raw)
                if not msg then
                    if raw.t == 'call' and type(raw.id) == 'string' and raw.id ~= '' then
                        safe.pcall(function() send_frame(protocol.reply_err(raw.id, 'bad_message: ' .. tostring(verr))) end)
                    elseif raw.t == 'xfer_begin' and type(raw.id) == 'string' and raw.id ~= '' then
                        safe.pcall(function() send_frame(protocol.xfer_ready(raw.id, false, nil, 'bad_message: ' .. tostring(verr))) end)
                    end
                    note_bad_frame('invalid_message', verr, raw.t, line)
                else
                    mark_rx(msg)

                    if msg.t == 'hello' then
                        local okh, herr = validate_peer_hello(msg)
                        if not okh then
                            note_bad_frame('bad_hello', herr, msg.t)
                        else
                            note_peer_identity(msg)
                            local ok2, err2 = send_frame(protocol.hello_ack(state.node_id, { sid = state.local_sid }))
                            if ok2 ~= true then
                                svc:obs_log('warn', { what = 'hello_ack_failed', link_id = link_id, err = tostring(err2) })
                            end
                        end

                    elseif msg.t == 'hello_ack' then
                        local oka, aerr = validate_peer_ack(msg)
                        if not oka then
                            note_bad_frame('bad_hello_ack', aerr, msg.t)
                        elseif msg.ok == false then
                            note_bad_frame('hello_ack_rejected', 'peer rejected session', msg.t)
                        else
                            note_peer_identity(msg)
                        end

                    elseif msg.t == 'ping' then
                        note_peer_sid_only(msg)
                        local ok2, err2 = send_frame(protocol.pong({ sid = state.local_sid }))
                        if ok2 ~= true then
                            svc:obs_log('warn', { what = 'pong_send_failed', link_id = link_id, err = tostring(err2) })
                        end

                    elseif msg.t == 'pong' then
                        note_peer_sid_only(msg)

                    elseif xfer and xfer:is_transfer_message(msg) then
                        if msg.t == 'xfer_chunk' and (msg.seq == 0 or (msg.seq % 32) == 31) then
                            svc:obs_log('info', {
                                what     = 'xfer_chunk_rx',
                                link_id  = link_id,
                                id       = msg.id,
                                seq      = msg.seq,
                                off      = msg.off,
                                n        = msg.n,
                                data_len = type(msg.data) == 'string' and #msg.data or nil,
                                line_len = #line,
                            })
                        end
                        local okx, xerr = xfer:handle_incoming(msg)
                        if okx ~= true then
                            svc:obs_log('warn', {
                                what    = 'transfer_message_failed',
                                link_id = link_id,
                                err     = tostring(xerr),
                                t       = tostring(msg.t),
                            })
                        end

                    elseif msg.t == 'pub' then
                        local _, perr = handle_incoming_pub(peer_conn, link_cfg, msg)
                        if perr then
                            svc:obs_log('warn', { what = 'incoming_pub_dropped', link_id = link_id, err = tostring(perr) })
                        end

                    elseif msg.t == 'unretain' then
                        local _, uerr = handle_incoming_unretain(peer_conn, link_cfg, msg)
                        if uerr then
                            svc:obs_log('warn', { what = 'incoming_unretain_dropped', link_id = link_id, err = tostring(uerr) })
                        end

                    elseif msg.t == 'call' then
                        local ok_call, call_err = handle_incoming_call(peer_conn, send_frame, link_cfg, msg)
                        if ok_call ~= true then
                            svc:obs_log('warn', { what = 'incoming_call_failed', link_id = link_id, err = tostring(call_err) })
                        end

                    elseif msg.t == 'reply' then
                        pending:deliver(msg.corr, msg)

                    else
                        svc:obs_log('warn', { what = 'unknown_message_type', link_id = link_id, t = tostring(msg.t) })
                    end
                end
            end
        end
    end
end

return M
