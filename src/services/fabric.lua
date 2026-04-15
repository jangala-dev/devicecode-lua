-- services/fabric.lua
--
-- Fabric service for the dev branch.
--
-- Design notes:
--   * follows the capability-led HAL shape used in this branch
--   * does not proxy UART bytes over the bus
--   * consumes retained cfg/fabric
--   * spawns one child scope per configured link
--   * exposes firmware transfer RPCs over the bus

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local sleep   = require 'fibers.sleep'
local safe    = require 'coxpcall'

local base       = require 'devicecode.service_base'
local config_mod = require 'services.fabric.config'
local session    = require 'services.fabric.session'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local M = {}

local function t(...)
    return { ... }
end

local function stop_children(children)
    for _, rec in pairs(children) do
        if rec and rec.ctrl_tx then
            safe.pcall(function() rec.ctrl_tx:close('fabric reconfigure') end)
        end
        if rec and rec.scope then
            rec.scope:cancel('fabric reconfigure')
        end
    end
end

local function reply_rpc(conn, msg, payload)
    if msg and msg.reply_to ~= nil then
        return conn:publish_one(msg.reply_to, payload, { id = msg.id })
    end
    return false, 'no_reply_to'
end

local function ask_child(rec, job, timeout_s)
    if not rec or not rec.ctrl_tx then
        return nil, 'link is unavailable'
    end

    local tx, rx = mailbox.new(1, { full = 'reject_newest' })
    local req = {}
    for k, v in pairs(job or {}) do req[k] = v end
    req.reply_tx = tx

    local ok, err = rec.ctrl_tx:send(req)
    if ok ~= true then
        tx:close('enqueue_failed')
        if ok == nil then return nil, 'control closed' end
        return nil, tostring(err or 'control full')
    end

    local which, a = perform(named_choice {
        reply = rx:recv_op(),
        timer = sleep.sleep_op(timeout_s or 3.0):wrap(function() return true end),
    })

    if which == 'timer' then
        tx:close('timeout')
        return nil, 'timeout'
    end

    if a == nil then
        return nil, 'control closed'
    end

    return a, nil
end

local function valid_source(x)
    return type(x) == 'table'
        and type(x.open) == 'function'
        and type(x.size) == 'function'
        and type(x.sha256hex) == 'function'
end

local function drop_transfers_for_link(transfers, link_id)
    for transfer_id, rec in pairs(transfers) do
        if rec and rec.link_id == link_id then
            transfers[transfer_id] = nil
        end
    end
end

function M.start(conn, opts)
    opts = opts or {}
    if type(opts.connect) ~= 'function' then
        error('fabric: opts.connect(principal) is required', 2)
    end

    local svc = base.new(conn, { name = opts.name or 'fabric', env = opts.env })

    svc:status('starting')
    svc:obs_log('info', { what = 'start_entered' })

    conn:retain(t('svc', svc.name, 'announce'), {
        role = 'fabric',
        caps = {
            pub_proxy     = true,
            call_proxy    = true,
            uart_stream   = true,
            blob_transfer = true,
            firmware_push = true,
        },
    })

    local root = fibers.current_scope()
    local children = {}
    local current_gen = 0
    local transfers = {} -- transfer_id -> { link_id = ..., transfer = last_seen_snapshot }

    local function watch_child(link_id, rec)
        fibers.spawn(function()
            -- IMPORTANT: observe the child scope via not_ok_op (passive),
            -- never call join_op directly here. join_op transitions the
            -- scope to _join_started as soon as its block_fn runs, which
            -- races session.run's own fibers.spawn calls — session.run
            -- yields early during transport:open(), this watcher then
            -- runs, join_op kicks _start_join_worker, and any subsequent
            -- fibers.spawn in session.run is rejected with 'scope is
            -- joining'. The result is a session where the rx reader
            -- fiber, export publishers, retained watchers and proxy
            -- endpoints all silently fail to start and the link hangs
            -- after link_up without ever processing incoming frames.
            --
            -- devicecode/main.lua:244 uses the same not_ok_op -> join_op
            -- pattern for its own supervisor; follow it here.
            perform(rec.scope:not_ok_op())
            local st, report, primary = perform(rec.scope:join_op())

            if children[link_id] == rec then
                children[link_id] = nil
                drop_transfers_for_link(transfers, link_id)
            end

            svc:obs_log((st == 'failed') and 'error' or 'warn', {
                what    = 'link_session_exit',
                link_id = link_id,
                status  = st,
                primary = tostring(primary),
                report  = report,
            })

            conn:retain(t('state', 'fabric', 'link', link_id), {
                link_id = link_id,
                status  = 'down',
                ready   = false,
                err     = tostring(primary or st),
                t       = svc:now(),
            })
        end)
    end

    local function apply_config(cfg)
        current_gen = current_gen + 1
        local gen = current_gen

        stop_children(children)
        children = {}
        transfers = {}

        for link_id, link_cfg in pairs(cfg.links) do
            local child, cerr = root:child()
            if not child then
                svc:obs_log('error', {
                    what    = 'link_child_failed',
                    link_id = link_id,
                    err     = tostring(cerr),
                })
            else
                local ctrl_tx, ctrl_rx = mailbox.new(8, { full = 'reject_newest' })

                local ok_spawn, serr = child:spawn(function()
                    return session.run(conn, svc, {
                        gen        = gen,
                        link_id    = link_id,
                        link       = link_cfg,
                        connect    = opts.connect,
                        node_id    = opts.node_id,
                        control_rx = ctrl_rx,
                        sink_factory = opts.sink_factory,
                    })
                end)

                if not ok_spawn then
                    safe.pcall(function() ctrl_tx:close('spawn failed') end)
                    child:cancel('spawn failed')
                    svc:obs_log('error', {
                        what    = 'link_spawn_failed',
                        link_id = link_id,
                        err     = tostring(serr),
                    })
                else
                    local rec = {
                        scope   = child,
                        cfg     = link_cfg,
                        ctrl_tx = ctrl_tx,
                    }
                    children[link_id] = rec
                    watch_child(link_id, rec)
                end
            end
        end

        svc:status('running', {
            links = cfg.link_count,
            gen   = gen,
        })
        svc:obs_event('config_applied', {
            gen   = gen,
            links = cfg.link_count,
        })
        conn:retain(t('state', 'fabric', 'main'), {
            status = 'running',
            gen    = gen,
            links  = cfg.link_count,
            t      = svc:now(),
        })
    end

    local function handle_send_firmware(payload)
        if type(payload) ~= 'table' then
            return { ok = false, err = 'payload must be a table' }
        end

        local link_id = payload.link_id
        if type(link_id) ~= 'string' or link_id == '' then
            return { ok = false, err = 'link_id must be a non-empty string' }
        end

        local source = payload.source or payload.blob
        if not valid_source(source) then
            return { ok = false, err = 'source is not a valid blob source' }
        end

        local rec = children[link_id]
        if not rec then
            return { ok = false, err = 'unknown link: ' .. tostring(link_id) }
        end

        local meta = type(payload.meta) == 'table' and payload.meta or {}
        if meta.kind == nil then meta.kind = 'firmware.rp2350' end
        if meta.name == nil and type(source.name) == 'function' then meta.name = source:name() end
        if meta.format == nil and type(source.format) == 'function' then meta.format = source:format() or 'bin' end
        if meta.format == nil then meta.format = 'bin' end

        local reply, err = ask_child(rec, {
            op     = 'send_blob',
            source = source,
            meta   = meta,
        }, 2.0)

        if not reply then
            return { ok = false, err = tostring(err) }
        end

        if reply.ok == true and type(reply.transfer_id) == 'string' then
            transfers[reply.transfer_id] = {
                link_id  = link_id,
                transfer = {
                    id         = reply.transfer_id,
                    link_id    = link_id,
                    status     = 'starting',
                    updated_at = svc:now(),
                },
            }
        end

        return reply
    end

    local function handle_transfer_status(payload)
        if type(payload) ~= 'table' then
            return { ok = false, err = 'payload must be a table' }
        end

        local transfer_id = payload.transfer_id
        if type(transfer_id) ~= 'string' or transfer_id == '' then
            return { ok = false, err = 'transfer_id must be a non-empty string' }
        end

        local rec = transfers[transfer_id]
        if not rec then
            return { ok = false, err = 'unknown transfer' }
        end

        local child = children[rec.link_id]
        if not child then
            transfers[transfer_id] = nil
            return { ok = false, err = 'transfer is no longer active' }
        end

        local reply, err = ask_child(child, {
            op          = 'transfer_status',
            transfer_id = transfer_id,
        }, 2.0)

        if not reply then
            return { ok = false, err = tostring(err) }
        end

        if reply.ok == true and type(reply.transfer) == 'table' then
            rec.transfer = reply.transfer
        end

        return reply
    end

    local function handle_transfer_abort(payload)
        if type(payload) ~= 'table' then
            return { ok = false, err = 'payload must be a table' }
        end

        local transfer_id = payload.transfer_id
        if type(transfer_id) ~= 'string' or transfer_id == '' then
            return { ok = false, err = 'transfer_id must be a non-empty string' }
        end

        local rec = transfers[transfer_id]
        if not rec then
            return { ok = false, err = 'unknown transfer' }
        end

        local child = children[rec.link_id]
        if not child then
            transfers[transfer_id] = nil
            return { ok = false, err = 'transfer is no longer active' }
        end

        local reply, err = ask_child(child, {
            op          = 'transfer_abort',
            transfer_id = transfer_id,
            reason      = payload.reason or 'aborted_by_user',
        }, 2.0)

        if not reply then
            return { ok = false, err = tostring(err) }
        end

        return reply
    end

    local function endpoint_worker(ep, handler, name)
        fibers.spawn(function()
            while true do
                local msg, err = perform(ep:recv_op())
                if not msg then
                    svc:obs_log('warn', {
                        what = 'rpc_endpoint_stopped',
                        name = name,
                        err  = tostring(err),
                    })
                    return
                end

                local ok, reply = safe.pcall(function()
                    return handler(msg.payload or {})
                end)

                if not ok then
                    reply = { ok = false, err = tostring(reply) }
                end

                local pub_ok, pub_err = reply_rpc(conn, msg, reply)
                if pub_ok ~= true then
                    svc:obs_log('warn', {
                        what = 'rpc_reply_failed',
                        name = name,
                        err  = tostring(pub_err),
                    })
                end
            end
        end)
    end

    local ep_send_fw = conn:bind(t('rpc', svc.name, 'send_firmware'), { queue_len = 8 })
    local ep_status  = conn:bind(t('rpc', svc.name, 'transfer_status'), { queue_len = 8 })
    local ep_abort   = conn:bind(t('rpc', svc.name, 'transfer_abort'), { queue_len = 8 })

    endpoint_worker(ep_send_fw, handle_send_firmware, 'send_firmware')
    endpoint_worker(ep_status,  handle_transfer_status, 'transfer_status')
    endpoint_worker(ep_abort,   handle_transfer_abort, 'transfer_abort')

    local sub_cfg = conn:subscribe(t('cfg', 'fabric'), {
        queue_len = 4,
        full      = 'drop_oldest',
    })

    svc:spawn_heartbeat(30.0, 'tick')

    svc:status('waiting_config')
    svc:obs_log('info', { what = 'waiting_for_config' })

    while true do
        local msg, err = fibers.perform(sub_cfg:recv_op())
        if not msg then
            svc:status('failed', { reason = err })
            error(('fabric: config subscription ended: %s'):format(tostring(err)), 0)
        end

        local payload = msg.payload
        local cfg_payload = payload

        if type(payload) == 'table' and type(payload.data) == 'table' then
            cfg_payload = payload.data
        end

        local cfg, cerr = config_mod.normalise(cfg_payload)
        if not cfg then
            svc:obs_log('warn', {
                what = 'bad_config',
                err  = tostring(cerr),
            })
        else
            apply_config(cfg)
        end
    end
end

return M
