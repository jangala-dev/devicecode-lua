-- tests/integration/devhost/support/mcu_http_uart_child.lua
--
-- Separate-process fake MCU for the HTTP-over-UART devhost test.  This keeps
-- the MCU bus, scheduler and HAL UART manager out of the parent test process
-- while still using the real Fabric and HAL UART open path on the MCU side.

local function add_path(prefix)
    package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

package.path = '../src/?.lua;' .. package.path
package.path = '../?.lua;../?/init.lua;./?.lua;./?/init.lua;' .. package.path
add_path('../vendor/lua-fibers/src/')
add_path('../vendor/lua-bus/src/')
add_path('../vendor/lua-trie/src/')
add_path('./')

local stdlib_ok, stdlib = pcall(require, 'posix.stdlib')
if stdlib_ok and stdlib and stdlib.setenv then
    stdlib.setenv('CONFIG_TARGET', 'services', true)
end

local busmod  = require 'bus'
local fibers  = require 'fibers'
local channel = require 'fibers.channel'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local socket  = require 'fibers.io.socket'
local safe    = require 'coxpcall'

local cjson_ok, cjson = pcall(require, 'cjson.safe')
if not cjson_ok then cjson = require 'cjson' end

local hal_types = require 'services.hal.types.core'
local cap_args  = require 'services.hal.types.capability_args'
local fabric    = require 'services.fabric'
local fabric_topics = require 'services.fabric.topics'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local xxhash32 = require 'shared.hash.xxhash32'

local UART_BYTES_PER_SEC = 11520
local REALISTIC_TRANSFER_TIMEOUT_S = tonumber(os.getenv('MCU_HTTP_UART_TRANSFER_TIMEOUT_S')) or 300.0
local MCU_PROGRESS_LOG_BYTES = 16 * 1024
local MCU_FLASH_WRITE_DELAY_S = tonumber(os.getenv('MCU_HTTP_UART_FLASH_DELAY_S')) or 0.010

local function parse_args(argv)
    local out = {}
    local i = 1
    while i <= #argv do
        local k = argv[i]
        if k == '--ipc' then i = i + 1; out.ipc = argv[i]
        elseif k == '--uart' then i = i + 1; out.uart = argv[i]
        elseif k == '--old-image' then i = i + 1; out.old_image_id = argv[i]
        elseif k == '--committed-image' then i = i + 1; out.committed_image_id = argv[i] ~= '' and argv[i] or nil
        elseif k == '--boot-seq' then i = i + 1; out.boot_seq = tonumber(argv[i]) or 1
        else error('unknown argument: ' .. tostring(k), 0) end
        i = i + 1
    end
    assert(out.ipc and out.ipc ~= '', '--ipc required')
    assert(out.uart and out.uart ~= '', '--uart required')
    out.old_image_id = out.old_image_id or 'mcu-image-old'
    return out
end

local function assert_true(v, msg) if v ~= true then error(msg or ('expected true, got ' .. tostring(v)), 0) end end
local function assert_not_nil(v, msg) if v == nil then error(msg or 'expected non-nil', 0) end end
local function assert_eq(a, b, msg) if a ~= b then error(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)), 0) end end

local function dummy_logger()
    local logger = {}
    for _, k in ipairs({ 'debug', 'info', 'warn', 'error' }) do logger[k] = function () end end
    function logger:child() return self end
    return logger
end

local function wait_channel_get(ch, timeout_s, what)
    local which, a, b = fibers.perform(op.named_choice({
        item = ch:get_op(),
        timeout = sleep.sleep_op(timeout_s or 1.0),
    }))
    if which == 'timeout' then error(('timed out waiting for %s'):format(what or 'channel item'), 0) end
    if a == nil then error(('channel closed while waiting for %s: %s'):format(what or 'channel item', tostring(b)), 0) end
    return a
end

local function wait_device_event(dev_ev_ch, event_type, class, id, timeout_s)
    local deadline = fibers.now() + (timeout_s or 1.5)
    while fibers.now() < deadline do
        local ev = wait_channel_get(dev_ev_ch, deadline - fibers.now(), 'UART device event')
        if ev.event_type == event_type and ev.class == class and ev.id == id then return ev end
    end
    error(('timed out waiting for UART device event %s %s/%s'):format(tostring(event_type), tostring(class), tostring(id)), 0)
end

local function wait_uart_cap(dev_ev_ch)
    local added = wait_device_event(dev_ev_ch, 'added', 'uart', 'uart0', 1.5)
    assert_true(type(added.capabilities) == 'table' and #added.capabilities == 1, 'UART added event missing capability')
    local cap = added.capabilities[1]
    assert_eq(cap.class, 'uart')
    assert_eq(cap.id, 'uart0')
    assert_true(type(cap.control_ch) == 'table', 'UART capability should expose control_ch')
    return cap
end

local function normalise_uart_open_opts(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.UARTOpenOpts then
        local open_opts, err = cap_args.new.UARTOpenOpts(opts)
        assert_not_nil(open_opts, tostring(err))
        return open_opts
    end
    return opts
end

local function call_hal_control(cap, verb, opts)
    local reply_ch = channel.new(1)
    local req, err = hal_types.new.ControlRequest(verb, opts or {}, reply_ch)
    assert_not_nil(req, tostring(err))
    fibers.perform(cap.control_ch:put_op(req))
    local reply = wait_channel_get(reply_ch, 1.0, 'HAL UART control reply')
    assert_true(type(reply) == 'table', 'HAL control reply must be a table')
    return reply
end

local function expose_raw_host_uart_open(scope, bus, cap, source)
    source = source or 'uart_manager'
    local conn = bus:connect({ origin_base = { service = 'mcu-child-hal-uart-adapter' } })
    local cap_id = cap.id
    local ep = conn:bind({ 'raw', 'host', source, 'cap', 'uart', cap_id, 'rpc', 'open' }, { queue_len = 8 })

    conn:retain({ 'raw', 'host', source, 'status' }, { state = 'available', available = true, source = source, class = 'uart', id = cap_id })
    conn:retain({ 'raw', 'host', source, 'meta' }, { source = source, class = 'uart', id = cap_id })
    conn:retain({ 'raw', 'host', source, 'cap', 'uart', cap_id, 'status' }, { state = 'available', available = true, source_kind = 'host', source = source })
    conn:retain({ 'raw', 'host', source, 'cap', 'uart', cap_id, 'meta' }, { source_kind = 'host', source = source, offerings = { open = true } })

    scope:finally(function ()
        safe.pcall(function () ep:unbind() end)
        bus_cleanup.disconnect(conn)
    end)

    assert_true(scope:spawn(function ()
        while true do
            local req = ep:recv()
            if req == nil then return end
            local open_opts = normalise_uart_open_opts(req.payload)
            local reply = call_hal_control(cap, 'open', open_opts)
            local replied = req:reply(reply)
            if not replied and reply.ok == true and type(reply.reason) == 'table'
                and type(reply.reason.session) == 'table'
                and type(reply.reason.session.terminate) == 'function'
            then
                reply.reason.session:terminate('fabric request abandoned')
            end
        end
    end))

    return { source = source, class = 'uart', id = cap_id }
end

local function fresh_uart_manager()
    package.loaded['services.hal.managers.uart'] = nil
    package.loaded['services.hal.drivers.uart'] = nil
    return require 'services.hal.managers.uart'
end

local function start_uart_manager(scope, bus, uart_slave)
    local uart_mgr = fresh_uart_manager()
    local dev_ev_ch = channel.new(16)
    local cap_emit_ch = channel.new(32)
    local ok_start, start_err = fibers.perform(uart_mgr.start_op(dummy_logger(), dev_ev_ch, cap_emit_ch))
    assert_true(ok_start, tostring(start_err))
    scope:finally(function () safe.pcall(function () fibers.perform(uart_mgr.shutdown_op()) end) end)

    local ok_cfg, cfg_err = fibers.perform(uart_mgr.apply_config_op({
        { id = 'uart0', path = uart_slave, baud = 115200, mode = '8N1' },
    }))
    assert_true(ok_cfg, tostring(cfg_err))
    local cap = wait_uart_cap(dev_ev_ch)
    return expose_raw_host_uart_open(scope, bus, cap, 'uart_manager')
end


local function fabric_payload_snapshot(payload)
    if type(payload) ~= 'table' then return nil end
    return type(payload.snapshot) == 'table' and payload.snapshot or payload
end

local function compact_fabric_session(s)
    s = type(s) == 'table' and s or {}
    return ('phase=%s established=%s local=%s peer_node=%s peer_sid=%s gen=%s wire_errors=%s bad_frames=%s last_wire_error=%s why=%s'):format(
        tostring(s.phase), tostring(s.established), tostring(s.local_node), tostring(s.peer_node),
        tostring(s.peer_sid), tostring(s.session_generation), tostring(s.wire_errors or 0),
        tostring(s.bad_frame_count or 0), tostring(s.last_wire_error), tostring(s.why)
    )
end

local function compact_fabric_bridge(s)
    s = type(s) == 'table' and s or {}
    return ('state=%s imported=%s pending=%s inbound=%s frames_sent=%s frames_recv=%s session_peer=%s drop=%s err=%s'):format(
        tostring(s.state), tostring(s.imported_topics), tostring(s.pending_calls), tostring(s.inbound_calls),
        tostring(s.frames_sent), tostring(s.frames_received),
        tostring(type(s.session) == 'table' and s.session.peer_sid or nil),
        tostring(s.session_drop_reason), tostring(s.last_err)
    )
end

local function compact_fabric_transfer(s)
    s = type(s) == 'table' and s or {}
    local stats = type(s.stats) == 'table' and s.stats or {}
    local active = type(s.active) == 'table' and s.active or nil
    local last = type(s.last) == 'table' and s.last or nil
    return ('active=%s active_status=%s last_status=%s completed=%s failed=%s cancelled=%s stale=%s'):format(
        tostring(active ~= nil), tostring(active and active.status), tostring(last and last.status),
        tostring(stats.completed), tostring(stats.failed), tostring(stats.cancelled), tostring(stats.stale)
    )
end

local function compact_fabric_link(s)
    s = type(s) == 'table' and s or {}
    local comps = {}
    if type(s.components) == 'table' then
        for name, rec in pairs(s.components) do
            comps[#comps + 1] = tostring(name) .. '=' .. tostring(type(rec) == 'table' and rec.status or rec)
        end
        table.sort(comps)
    end
    return ('state=%s completed=%s/%s reason=%s components=[%s]'):format(
        tostring(s.state), tostring(s.completed), tostring(s.total), tostring(s.reason), table.concat(comps, ',')
    )
end

local function describe_fabric_status_payload(payload, component)
    local s = fabric_payload_snapshot(payload)
    if component == 'session' then return compact_fabric_session(s) end
    if component == 'rpc_bridge' then return compact_fabric_bridge(s) end
    if component == 'transfer_manager' or component == 'transfer' then return compact_fabric_transfer(s) end
    return compact_fabric_link(s)
end

local function retained_payload_now(conn, topic)
    local view = conn:retained_view(topic)
    local msg = view:get(topic)
    view:close()
    return msg and msg.payload or nil
end

local function wait_retained_payload_where(conn, topic, label, pred, timeout_s)
    local view = conn:retained_view(topic)
    local deadline = fibers.now() + (timeout_s or 6.0)
    local seen = view:version()
    while true do
        local msg = view:get(topic)
        local payload = msg and msg.payload or nil
        local out = pred(payload)
        if out then view:close(); return out end
        local remaining = deadline - fibers.now()
        if remaining <= 0 then view:close(); error('timed out waiting for ' .. tostring(label), 0) end
        local which, version, reason = fibers.perform(op.named_choice({
            changed = view:changed_op(seen),
            timeout = sleep.sleep_op(math.min(0.50, remaining)),
        }))
        if which == 'changed' then
            if version == nil then view:close(); error(tostring(label) .. ' closed: ' .. tostring(reason or 'closed'), 0) end
            seen = version
        end
    end
end

local function start_fabric_status_reporter(scope, conn, emit)
    assert_true(scope:spawn(function ()
        local payload = wait_retained_payload_where(
            conn,
            fabric_topics.state_link_component('link-a', 'session'),
            'MCU fabric session established',
            function (p)
                local s = fabric_payload_snapshot(p)
                if type(s) == 'table' and s.established == true and type(s.peer_sid) == 'string' and s.peer_sid ~= '' then
                    return p
                end
                return nil
            end,
            6.0
        )
        local s = fabric_payload_snapshot(payload) or {}
        emit({
            event = 'fabric_session',
            phase = s.phase,
            established = s.established,
            local_node = s.local_node,
            peer_node = s.peer_node,
            peer_sid = s.peer_sid,
            session_generation = s.session_generation,
            wire_errors = s.wire_errors or 0,
            bad_frame_count = s.bad_frame_count or 0,
            last_wire_error = s.last_wire_error,
            summary = describe_fabric_status_payload(payload, 'session'),
        })
        local items = {
            { label = 'link', topic = fabric_topics.state_link('link-a') },
            { label = 'session', component = 'session', topic = fabric_topics.state_link_component('link-a', 'session') },
            { label = 'rpc_bridge', component = 'rpc_bridge', topic = fabric_topics.state_link_component('link-a', 'rpc_bridge') },
            { label = 'transfer_manager', component = 'transfer_manager', topic = fabric_topics.state_link_component('link-a', 'transfer_manager') },
        }
        for _, item in ipairs(items) do
            local p = retained_payload_now(conn, item.topic)
            emit({ event = 'fabric_status', component = item.label, summary = describe_fabric_status_payload(p, item.component) })
        end
    end))
end

local function fabric_config(local_node, peer_node, bridge, transfer)
    return {
        schema = fabric.config.SCHEMA,
        local_node = local_node,
        links = {
            {
                id = 'link-a',
                peer_id = peer_node,
                transport = { source = 'uart_manager', class = 'uart', id = 'uart0', terminator = '\n' },
                session = { hello_interval_s = 0.20, ping_interval_s = 5.0, liveness_timeout_s = 5.0 },
                bridge = bridge or {},
                transfer = transfer or { chunk_size = 2048, timeout_s = REALISTIC_TRANSFER_TIMEOUT_S },
            },
        },
    }
end

local function mcu_fabric_config()
    return fabric_config('mcu', 'cm5', {
        exports = {
            { id = 'mcu-state-export', ['local'] = { 'state', 'self' }, remote = { 'state', 'self' }, publish = true, retain = true },
            { id = 'mcu-cap-export', ['local'] = { 'cap', 'self' }, remote = { 'cap', 'self' }, publish = true, retain = true },
        },
        rpc = {
            inbound = {
                { id = 'mcu-prepare-in', ['local'] = { 'cap', 'self', 'updater', 'main', 'rpc', 'prepare-update' }, remote = { 'cap', 'self', 'updater', 'main', 'rpc', 'prepare-update' }, timeout_s = 2.0 },
                { id = 'mcu-commit-in', ['local'] = { 'cap', 'self', 'updater', 'main', 'rpc', 'commit-update' }, remote = { 'cap', 'self', 'updater', 'main', 'rpc', 'commit-update' }, timeout_s = 2.0 },
            },
        },
    }, { chunk_size = 2048, timeout_s = REALISTIC_TRANSFER_TIMEOUT_S })
end

local function start_public_fabric(scope, conn, cfg, opts)
    opts = opts or {}
    assert_true(scope:spawn(function ()
        fabric.start(conn, {
            name = opts.name or 'fabric-mcu-child',
            env = 'test',
            config = cfg,
            link_overrides = opts.link_overrides,
        })
    end))
end

local function publish_mcu_facts(conn, fake)
    local image = fake.committed_image_id or fake.old_image_id
    local boot = 'mcu-boot-' .. tostring(fake.boot_seq)
    conn:retain({ 'state', 'self', 'software' }, { image_id = image, boot_id = boot, version = image })
    conn:retain({ 'state', 'self', 'updater' }, {
        state = 'ready',
        last_error = nil,
        staged_image_id = fake.staged and fake.staged.image_id or nil,
        pending_image_id = fake.committed_image_id,
        job_id = fake.job_id,
    })
    conn:retain({ 'cap', 'self', 'updater', 'main', 'meta' }, { class = 'updater', id = 'main', methods = { 'prepare-update', 'commit-update' } })
    conn:retain({ 'cap', 'self', 'updater', 'main', 'status' }, { available = true, state = 'available' })
end

local function new_mcu_receive_target(fake, emit)
    local target = {}
    function target:open_sink_op(req)
        fake.transfer_begin = req
        fake.receive_started_at = fibers.now()
        fake.receive_bytes = 0
        fake.receive_chunks = 0
        fake.receive_next_log = MCU_PROGRESS_LOG_BYTES
        assert_eq(req.target, 'updater/main')
        emit({ event = 'receive_opened', target = req.target, size = req.size, job_id = req.meta and req.meta.job_id, image_id = req.meta and (req.meta.image_id or req.meta.expected_image_id) })
        local chunks = {}
        local sink = {}
        function sink:append_op(chunk)
            return fibers.run_scope_op(function ()
                fibers.perform(sleep.sleep_op(MCU_FLASH_WRITE_DELAY_S))
                chunks[#chunks + 1] = chunk
                fake.receive_bytes = (fake.receive_bytes or 0) + #(chunk or '')
                fake.receive_chunks = (fake.receive_chunks or 0) + 1
                if fake.receive_bytes >= (fake.receive_next_log or MCU_PROGRESS_LOG_BYTES) then
                    local elapsed = fibers.now() - (fake.receive_started_at or fibers.now())
                    emit({ event = 'receive_progress', bytes = fake.receive_bytes, chunks = fake.receive_chunks or 0, elapsed_s = elapsed })
                    fake.receive_next_log = fake.receive_bytes + MCU_PROGRESS_LOG_BYTES
                else
                    emit({ event = 'receive_tick', bytes = fake.receive_bytes, chunks = fake.receive_chunks or 0 })
                end
                return true, nil
            end):wrap(function (status, _report, ok, err)
                if status ~= 'ok' then return nil, err or status end
                return ok, err
            end)
        end
        function sink:commit_op(req2)
            local bytes = table.concat(chunks)
            local payload_digest = xxhash32.digest_hex(bytes)
            fake.staged = { size = #bytes, digest = req2.digest, payload_digest = payload_digest, image_id = req.meta and (req.meta.image_id or req.meta.expected_image_id), job_id = req.meta and req.meta.job_id }
            fake.staged_signal = (fake.staged_signal or 0) + 1
            emit({ event = 'transfer_commit', size = #bytes, chunks = fake.receive_chunks or 0, digest = req2.digest, payload_digest = payload_digest, image_id = fake.staged.image_id, job_id = fake.staged.job_id })
            return op.always({ staged = true, digest = req2.digest }, nil)
        end
        function sink:abort(reason)
            fake.abort_reason = reason
            fake.abort_count = (fake.abort_count or 0) + 1
            emit({ event = 'transfer_abort', reason = tostring(reason), bytes = fake.receive_bytes or 0, chunks = fake.receive_chunks or 0, abort_count = fake.abort_count })
            return true, nil
        end
        return op.always(sink, nil)
    end
    return target
end

local function start_fake_mcu(scope, bus, fake, emit)
    local conn = bus:connect({ origin_base = { service = 'fake-mcu-child' } })
    publish_mcu_facts(conn, fake)

    local eps = {}
    local function bind(topic)
        local ep, err = bus_cleanup.bind(conn, topic, { queue_len = 8 })
        assert_not_nil(ep, err)
        eps[#eps + 1] = ep
        return ep
    end

    local prepare_ep = bind({ 'cap', 'self', 'updater', 'main', 'rpc', 'prepare-update' })
    local commit_ep = bind({ 'cap', 'self', 'updater', 'main', 'rpc', 'commit-update' })

    scope:finally(function ()
        for _, ep in ipairs(eps) do bus_cleanup.unbind(conn, ep) end
        bus_cleanup.disconnect(conn)
    end)

    assert_true(scope:spawn(function ()
        while true do
            local req = fibers.perform(prepare_ep:recv_op())
            if req == nil then return end
            fake.prepare_payload = req.payload
            assert_eq(type(req.payload) == 'table' and req.payload.target or nil, 'mcu')
            fake.job_id = type(req.payload) == 'table' and req.payload.job_id or nil
            conn:retain({ 'state', 'self', 'updater' }, { state = 'ready', last_error = nil, job_id = fake.job_id })
            emit({ event = 'prepare', payload = req.payload, job_id = fake.job_id })
            req:reply({ ready = true, target = 'updater/main', max_chunk_size = 2048 })
        end
    end))

    assert_true(scope:spawn(function ()
        while true do
            local req = fibers.perform(commit_ep:recv_op())
            if req == nil then return end
            fake.commit_payload = req.payload
            fake.commit_seen = true
            fake.committed_image_id = (fake.staged and fake.staged.image_id) or (type(req.payload) == 'table' and req.payload.expected_image_id)
            conn:retain({ 'state', 'self', 'updater' }, {
                state = 'rebooting',
                last_error = nil,
                pending_image_id = fake.committed_image_id,
                staged_image_id = fake.staged and fake.staged.image_id or nil,
                job_id = fake.job_id,
            })
            emit({ event = 'commit', payload = req.payload, committed_image_id = fake.committed_image_id })
            req:reply({ accepted = true, reboot_required = true })
        end
    end))

    return conn
end

local unix_ok, unistd = pcall(require, 'posix.unistd')
local child_pid = (unix_ok and unistd and unistd.getpid and tostring(unistd.getpid())) or ''

local function main(scope)
    local args = parse_args(arg or {})
    local ipc, ierr = socket.connect_unix(args.ipc)
    assert(ipc, 'IPC connect failed: ' .. tostring(ierr))

    local events = channel.new(256)
    local function emit(ev)
        ev = ev or {}
        ev.pid = child_pid
        local ok, err = fibers.perform(events:put_op(ev))
        return ok, err
    end

    scope:spawn(function ()
        while true do
            local ev = fibers.perform(events:get_op())
            if ev == nil then return end
            local line = assert(cjson.encode(ev)) .. '\n'
            local _, werr = fibers.perform(ipc:write_op(line))
            if werr then return end
        end
    end)

    local bus = busmod.new()
    local fake = {
        old_image_id = args.old_image_id,
        committed_image_id = args.committed_image_id,
        boot_seq = args.boot_seq,
    }

    start_uart_manager(scope, bus, args.uart)
    start_fake_mcu(scope, bus, fake, emit)

    local conn = bus:connect({ origin_base = { service = 'fabric-mcu-child' } })
    scope:finally(function () bus_cleanup.disconnect(conn) end)
    start_public_fabric(scope, conn, mcu_fabric_config(), {
        name = 'fabric-mcu-child',
        link_overrides = {
            ['link-a'] = {
                transfer = {
                    chunk_size = 2048,
                    timeout_s = REALISTIC_TRANSFER_TIMEOUT_S,
                    receive_targets = { ['updater/main'] = new_mcu_receive_target(fake, emit) },
                },
            },
        },
    })
    start_fabric_status_reporter(scope, conn, emit)

    emit({ event = 'ready', boot_seq = fake.boot_seq, image_id = fake.committed_image_id or fake.old_image_id, uart = args.uart })
    fibers.perform(op.never())
end

fibers.run(main)
