-- tests/integration/devhost/mcu_update_http_uart_spec.lua
--
-- Release-gate devhost MCU update flow over the real CM5 HAL UART boundary:
--   curl HTTP upload -> UI -> Update -> Device -> Fabric -> HAL UART -> PTY
--   middleware -> MCU-side Fabric -> fake MCU updater.
--
-- The middleware deliberately preserves the base Fabric protocol semantics. It
-- fragments and paces bytes like a modestly imperfect 115200 bps UART,
-- includes occasional non-corrupt stalls, a small fake flash-write delay on
-- the MCU side, and a small number of standalone malformed JSONL lines
-- between valid frames. It does not corrupt bytes inside a valid frame,
-- reorder frames, or ask the sender for future transfer offsets.

local busmod   = require 'bus'
local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'
local channel  = require 'fibers.channel'
local op       = require 'fibers.op'
local sleep    = require 'fibers.sleep'
local exec     = require 'fibers.io.exec'
local socket   = require 'fibers.io.socket'

local cjson_ok, cjson = pcall(require, 'cjson.safe')
if not cjson_ok then cjson = require 'cjson' end
local posix_ok, stdlib = pcall(require, 'posix.stdlib')
local safe = require 'coxpcall'

local http_request = require 'http.request'

local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'
local pty       = require 'tests.support.pty'
local dcmcu_fixture = require 'tests.support.dcmcu_fixture'

local bus_cleanup = require 'devicecode.support.bus_cleanup'

local hal_types = require 'services.hal.types.core'
local cap_args  = require 'services.hal.types.capability_args'

local hal_service    = require 'services.hal'
local http_service   = require 'services.http.service'
local ui_service     = require 'services.ui.service'
local update_service = require 'services.update.service'
local device_service = require 'services.device.service'
local fabric         = require 'services.fabric'

local http_driver_mod = require 'services.http.transport.cqueues_driver'
local hal_transport   = require 'services.fabric.hal_transport'
local fabric_protocol = require 'services.fabric.protocol'
local fabric_topics   = require 'services.fabric.topics'
local update_topics   = require 'services.update.topics'
local device_topics   = require 'services.device.topics'
local mcu_schema      = require 'services.device.schemas.mcu'
local http_topics     = require 'services.http.topics'
local xxhash32        = require 'shared.hash.xxhash32'

local T = {}
local unpack = rawget(table, 'unpack') or _G.unpack

local DEFAULT_CI_MCU_BLOB_BYTES = 6 * 1024
local LARGE_MCU_BLOB_ENV = 'MCU_HTTP_UART_BLOB_BYTES'

local function env_size_bytes(name, default_value)
    local raw = os.getenv(name)
    if raw == nil or raw == '' then return default_value end
    raw = tostring(raw):match('^%s*(.-)%s*$')
    local number, suffix = raw:match('^(%d+)%s*([kKmMgG]?[iI]?[bB]?)$')
    if number == nil then
        error(('invalid %s=%q; expected bytes, KiB, MiB or GiB, for example 204800 or 200K'):format(name, raw), 0)
    end
    local n = tonumber(number)
    suffix = suffix:lower()
    if suffix == 'k' or suffix == 'kb' or suffix == 'kib' then
        n = n * 1024
    elseif suffix == 'm' or suffix == 'mb' or suffix == 'mib' then
        n = n * 1024 * 1024
    elseif suffix == 'g' or suffix == 'gb' or suffix == 'gib' then
        n = n * 1024 * 1024 * 1024
    elseif suffix ~= '' and suffix ~= 'b' then
        error(('invalid %s=%q; expected bytes, KiB, MiB or GiB, for example 204800 or 200K'):format(name, raw), 0)
    end
    if n <= 0 then
        error(('%s must be positive'):format(name), 0)
    end
    return n
end


local function env_number(name, default_value)
    local raw = os.getenv(name)
    if raw == nil or raw == '' then return default_value end
    raw = tostring(raw):match('^%s*(.-)%s*$')
    local n = tonumber(raw)
    if n == nil or n <= 0 then
        error(('%s must be a positive number'):format(name), 0)
    end
    return n
end

local function env_bool(name, default_value)
    local raw = os.getenv(name)
    if raw == nil or raw == '' then return default_value end
    raw = tostring(raw):lower():match('^%s*(.-)%s*$')
    if raw == '1' or raw == 'true' or raw == 'yes' or raw == 'on' then return true end
    if raw == '0' or raw == 'false' or raw == 'no' or raw == 'off' then return false end
    error(('%s must be boolean-like'):format(name), 0)
end

local UART_BYTES_PER_SEC = env_number('MCU_HTTP_UART_BYTES_PER_SEC', env_number('MCU_HTTP_UART_BAUD', 921600) / 10)
local REALISTIC_MCU_BLOB_BYTES = env_size_bytes(LARGE_MCU_BLOB_ENV, DEFAULT_CI_MCU_BLOB_BYTES)
local REALISTIC_TRANSFER_TIMEOUT_S = 300.0
local SHORT_STAGE_TIMEOUT_S = 2.0
local REALISTIC_TEST_TIMEOUT_S = 240.0
local MCU_PROGRESS_LOG_BYTES = 16 * 1024
local WAIT_PROGRESS_LOG_S = env_number('MCU_HTTP_UART_WAIT_LOG_S', 10.0)
local UART_MAX_READ_BYTES = 128
local UART_MAX_FRAGMENT_BYTES = 16
local UART_LONG_PAUSE_EVERY_BYTES = 64 * 1024
local UART_LONG_PAUSE_BASE_S = 0.20
local UART_LONG_PAUSE_JITTER_S = 0.15
local UART_MALFORMED_LINE_COUNT = 2
local UART_MALFORMED_LINE_FIRST_AT = 1536
local UART_MALFORMED_LINE_EVERY_BYTES = 128 * 1024
local MCU_FLASH_WRITE_DELAY_S = 0.010
local MCU_HTTP_UART_VERBOSE = env_bool('MCU_HTTP_UART_VERBOSE', false)

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end
local function assert_contains(haystack, needle, msg)
    haystack = tostring(haystack or '')
    needle = tostring(needle or '')
    if haystack:find(needle, 1, true) == nil then
        fail(msg or ('expected ' .. haystack .. ' to contain ' .. needle))
    end
end

local function log(msg)
    if not MCU_HTTP_UART_VERBOSE then return end
    io.stderr:write('[mcu-http-uart] ' .. tostring(msg) .. '\n')
end

local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function env_non_empty(name)
    local v = os.getenv(name)
    if v == nil or v == '' then return nil end
    v = tostring(v):match('^%s*(.-)%s*$')
    if v == '' then return nil end
    return v
end


local function command_available(name)
    local cmd = exec.command('sh', '-c', 'command -v ' .. shquote(name) .. ' >/dev/null 2>&1')
    local _out, st, code = fibers.perform(cmd:combined_output_op())
    return st == 'exited' and code == 0
end

local function mkdir_p(path)
    local ok = os.execute('mkdir -p ' .. shquote(path))
    if ok ~= true and ok ~= 0 then error('mkdir failed: ' .. tostring(path), 0) end
end

local function rm_rf(path)
    os.execute('rm -rf ' .. shquote(path))
end

local function write_file(path, body)
    local f = assert(io.open(path, 'wb'))
    assert(f:write(body))
    assert(f:close())
end


local function sha256_hex_string(data)
    local path = os.tmpname()
    write_file(path, data)
    local script = table.concat({
        'set -eu',
        'if command -v sha256sum >/dev/null 2>&1; then',
        '  sha256sum ' .. shquote(path) .. " | awk '{ print $1 }'",
        'elif command -v shasum >/dev/null 2>&1; then',
        '  shasum -a 256 ' .. shquote(path) .. " | awk '{ print $1 }'",
        'else',
        "  echo 'sha256sum_or_shasum_required' >&2",
        '  exit 127',
        'fi',
    }, '\n')
    local cmd = exec.command('sh', '-c', script)
    local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
    rm_rf(path)
    if not (st == 'exited' and code == 0) then
        error(('sha256 helper failed: status=%s code=%s signal=%s err=%s output=%s'):format(
            tostring(st), tostring(code), tostring(sig), tostring(err), tostring(out)
        ), 0)
    end
    local hex = tostring(out or ''):match('([0-9a-fA-F]+)')
    if hex == nil or #hex ~= 64 then
        error('sha256 helper returned invalid digest: ' .. tostring(out), 0)
    end
    return hex:lower()
end

local function temp_roots()
    local base = ('/tmp/devicecode-mcu-http-uart-%d-%d'):format(os.time(), math.random(100000, 999999))
    rm_rf(base)
    local roots = {
        base = base,
        config = base .. '/config',
        static = base .. '/static',
        artifact = {
            transient = base .. '/cm5/artifacts/transient',
            durable = base .. '/cm5/artifacts/durable',
            import = base .. '/cm5/artifacts/import',
        },
        control = base .. '/cm5/control/update',
        mcu = base .. '/mcu',
    }
    mkdir_p(roots.config)
    mkdir_p(roots.static)
    mkdir_p(roots.artifact.transient)
    mkdir_p(roots.artifact.durable)
    mkdir_p(roots.artifact.import)
    mkdir_p(roots.control)
    mkdir_p(roots.mcu)
    write_file(roots.static .. '/index.html', 'ok')
    return roots
end

local function copy_frame(frame)
    local out = {}
    for k, v in pairs(frame or {}) do
        if type(v) == 'table' then
            local t = {}
            for k2, v2 in pairs(v) do t[k2] = v2 end
            out[k] = t
        else
            out[k] = v
        end
    end
    return out
end

local function new_line_transport()
    local in_tx, in_rx = mailbox.new(128, { full = 'reject_newest' })
    local written = {}
    local session = {}

    function session:read_line_op()
        return in_rx:recv_op():wrap(function(frame)
            if frame == nil then return nil, in_rx:why() or 'closed' end
            local line, err = fabric_protocol.encode_line(frame)
            if not line then return nil, err end
            return line, nil
        end)
    end

    function session:write_line_op(line)
        local frame, err = fabric_protocol.decode_line(line)
        if not frame then return fibers.always(nil, err) end
        written[#written + 1] = copy_frame(frame)
        return fibers.always(true, nil)
    end

    function session:flush_op()
        return fibers.always(true, nil)
    end

    function session:terminate(reason)
        in_tx:close(reason or 'transport terminated')
        return true, nil
    end

    return { session = session, in_tx = in_tx, written = written }
end

local function connect_line_transports(a, b)
    local write_a = a.session.write_line_op
    function a.session:write_line_op(line)
        local frame = assert(fabric_protocol.decode_line(line))
        write_a(self, line)
        return b.in_tx:send_op(copy_frame(frame))
    end

    local write_b = b.session.write_line_op
    function b.session:write_line_op(line)
        local frame = assert(fabric_protocol.decode_line(line))
        write_b(self, line)
        return a.in_tx:send_op(copy_frame(frame))
    end
end

local function wrap_session_op(session)
    local wrapped, err = hal_transport.wrap_transport(session)
    return fibers.always(wrapped, err)
end

local function wait_retained_payload_where(conn, topic, label, pred, opts)
    opts = opts or {}
    local view = conn:retained_view(topic)
    local value = probe.wait_versioned_until(label, function ()
        return view:version()
    end, function (seen)
        return view:changed_op(seen)
    end, function ()
        local msg = view:get(topic)
        local payload = msg and msg.payload or nil
        if pred(payload) then return payload end
        return nil
    end, opts)
    view:close()
    return value
end


local function topic_string(topic)
    if type(topic) ~= 'table' then return tostring(topic) end
    local out = {}
    for i = 1, #topic do out[i] = tostring(topic[i]) end
    return table.concat(out, '/')
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

local function log_fabric_status(conn, prefix)
    prefix = prefix or 'fabric'
    local topics = {
        { label = 'link', topic = fabric_topics.state_link('link-a') },
        { label = 'session', component = 'session', topic = fabric_topics.state_link_component('link-a', 'session') },
        { label = 'rpc_bridge', component = 'rpc_bridge', topic = fabric_topics.state_link_component('link-a', 'rpc_bridge') },
        { label = 'transfer_manager', component = 'transfer_manager', topic = fabric_topics.state_link_component('link-a', 'transfer_manager') },
    }
    for _, item in ipairs(topics) do
        local payload = retained_payload_now(conn, item.topic)
        log(('%s %s %s -> %s'):format(prefix, item.label, topic_string(item.topic), describe_fabric_status_payload(payload, item.component)))
    end
end

local function wait_fabric_session_established(conn, label, opts)
    opts = opts or {}
    local topic = fabric_topics.state_link_component('link-a', 'session')
    local payload = wait_retained_payload_where(conn, topic, label or 'fabric session established', function (p)
        local s = fabric_payload_snapshot(p)
        if type(s) == 'table' and s.established == true and type(s.peer_sid) == 'string' and s.peer_sid ~= '' then
            return p
        end
        return nil
    end, { timeout = opts.timeout or 6.0 })
    log((label or 'fabric session established') .. ': ' .. describe_fabric_status_payload(payload, 'session'))
    return payload
end


local function fabric_progress_fragment(conn)
    if conn == nil then return '' end
    local session = retained_payload_now(conn, fabric_topics.state_link_component('link-a', 'session'))
    local bridge = retained_payload_now(conn, fabric_topics.state_link_component('link-a', 'rpc_bridge'))
    local transfer = retained_payload_now(conn, fabric_topics.state_link_component('link-a', 'transfer_manager'))
    return ('fabric_session=(%s) fabric_bridge=(%s) fabric_transfer=(%s)'):format(
        describe_fabric_status_payload(session, 'session'),
        describe_fabric_status_payload(bridge, 'rpc_bridge'),
        describe_fabric_status_payload(transfer, 'transfer_manager')
    )
end

local function fresh_uart_manager()
    -- The UART manager is currently module-singleton state.  The filtered test
    -- runner still requires every spec module before it runs the selected test,
    -- so make this test's direct manager instance explicit and isolated.
    package.loaded['services.hal.managers.uart'] = nil
    package.loaded['services.hal.drivers.uart'] = nil
    return require 'services.hal.managers.uart'
end

local function dummy_logger()
    local logger = {}
    for _, k in ipairs({ 'debug', 'info', 'warn', 'error' }) do
        logger[k] = function () end
    end
    function logger:child() return self end
    return logger
end

local function wait_channel_get(ch, timeout_s, what)
    local which, a, b = fibers.perform(op.named_choice({
        item = ch:get_op(),
        timeout = sleep.sleep_op(timeout_s or 1.0),
    }))
    if which == 'timeout' then
        error(('timed out waiting for %s'):format(what or 'channel item'), 0)
    end
    if a == nil then
        error(('channel closed while waiting for %s: %s'):format(what or 'channel item', tostring(b)), 0)
    end
    return a
end

local function wait_until_test(label, pred, timeout_s, interval_s)
    local deadline = fibers.now() + (timeout_s or 2.0)
    while fibers.now() < deadline do
        if pred() then return true end
        fibers.perform(sleep.sleep_op(interval_s or 0.05))
    end
    error('timed out waiting for ' .. tostring(label), 0)
end

local function wait_device_event(dev_ev_ch, event_type, class, id, timeout_s)
    local deadline = fibers.now() + (timeout_s or 1.5)
    while fibers.now() < deadline do
        local ev = wait_channel_get(dev_ev_ch, deadline - fibers.now(), 'UART device event')
        if ev.event_type == event_type and ev.class == class and ev.id == id then
            return ev
        end
    end
    error(('timed out waiting for UART device event %s %s/%s'):format(
        tostring(event_type), tostring(class), tostring(id)
    ), 0)
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
    local conn = bus:connect({ origin_base = { service = 'hal-uart-test-adapter' } })
    local cap_id = cap.id
    local ep = conn:bind({ 'raw', 'host', source, 'cap', 'uart', cap_id, 'rpc', 'open' }, {
        queue_len = 8,
    })

    conn:retain({ 'raw', 'host', source, 'status' }, {
        state = 'available',
        available = true,
        source = source,
        class = 'uart',
        id = cap_id,
    })
    conn:retain({ 'raw', 'host', source, 'meta' }, {
        source = source,
        class = 'uart',
        id = cap_id,
    })
    conn:retain({ 'raw', 'host', source, 'cap', 'uart', cap_id, 'status' }, {
        state = 'available',
        available = true,
        source_kind = 'host',
        source = source,
    })
    conn:retain({ 'raw', 'host', source, 'cap', 'uart', cap_id, 'meta' }, {
        source_kind = 'host',
        source = source,
        offerings = { open = true },
    })

    -- Register cleanup before spawning work on this scope.  lua-fibers only
    -- allows adding finalisers to a started scope from within that same scope.
    scope:finally(function ()
        safe.pcall(function () ep:unbind() end)
        safe.pcall(function () conn:unretain({ 'raw', 'host', source, 'cap', 'uart', cap_id, 'meta' }) end)
        safe.pcall(function () conn:retain({ 'raw', 'host', source, 'cap', 'uart', cap_id, 'status' }, {
            state = 'removed',
            available = false,
            source_kind = 'host',
            source = source,
        }) end)
        safe.pcall(function () conn:unretain({ 'raw', 'host', source, 'meta' }) end)
        safe.pcall(function () conn:retain({ 'raw', 'host', source, 'status' }, {
            state = 'removed',
            available = false,
            source = source,
            class = 'uart',
            id = cap_id,
        }) end)
        bus_cleanup.disconnect(conn)
    end)

    local ok_spawn, spawn_err = scope:spawn(function ()
        while true do
            local req = ep:recv()
            if req == nil then return end

            local open_opts = normalise_uart_open_opts(req.payload)
            local reply = call_hal_control(cap, 'open', open_opts)

            local replied = req:reply(reply)
            if not replied
                and reply.ok == true
                and type(reply.reason) == 'table'
                and type(reply.reason.session) == 'table'
                and type(reply.reason.session.terminate) == 'function'
            then
                reply.reason.session:terminate('fabric request abandoned')
            end
        end
    end)
    assert_true(ok_spawn, tostring(spawn_err))

    return { source = source, class = 'uart', id = cap_id }
end

local function start_cm5_uart_manager(scope, bus, port)
    local uart_mgr = fresh_uart_manager()
    local dev_ev_ch = channel.new(16)
    local cap_emit_ch = channel.new(32)

    local ok_start, start_err = fibers.perform(uart_mgr.start_op(dummy_logger(), dev_ev_ch, cap_emit_ch))
    assert_true(ok_start, tostring(start_err))
    scope:finally(function ()
        safe.pcall(function () fibers.perform(uart_mgr.shutdown_op()) end)
    end)

    local ok_cfg, cfg_err = fibers.perform(uart_mgr.apply_config_op({
        serial_ports = {
        	{
        		id = 'uart0',
        		path = port.slave_name,
        		baud = 115200,
        		mode = '8N1',
        	},
        },
    }))
    assert_true(ok_cfg, tostring(cfg_err))

    local cap = wait_uart_cap(dev_ev_ch)
    local raw_cap = expose_raw_host_uart_open(scope, bus, cap, 'uart_manager')

    local conn = bus:connect({ origin_base = { service = 'hal-uart-test-wait' } })
    wait_retained_payload_where(conn, { 'raw', 'host', raw_cap.source, 'cap', raw_cap.class, raw_cap.id, 'status' },
        'HAL UART raw capability available', function (p)
            return p and p.available == true and p
        end, { timeout = 1.0 })
    bus_cleanup.disconnect(conn)

    return raw_cap
end

local function wait_job(conn, job_id, state, timeout)
    return wait_retained_payload_where(conn, update_topics.workflow_update_job(job_id), 'update job ' .. tostring(job_id) .. ' ' .. tostring(state), function (p)
        if p and p.state == state then return p end
        return nil
    end, { timeout = timeout or 4.0 })
end

local function describe_job_value(v, depth)
    depth = depth or 0
    if type(v) ~= 'table' then return tostring(v) end
    if depth >= 2 then return '<table>' end
    local parts = {}
    for k, vv in pairs(v) do
        if type(vv) ~= 'function' then
            parts[#parts + 1] = tostring(k) .. '=' .. describe_job_value(vv, depth + 1)
        end
    end
    table.sort(parts)
    return '{' .. table.concat(parts, ',') .. '}'
end

local function describe_job_progress(p)
    if type(p) ~= 'table' then return 'absent' end
    local parts = { 'state=' .. tostring(p.state) }
    if p.stage_attempt ~= nil then
        local st = p.stage_attempt
        parts[#parts + 1] = 'stage=' .. tostring(type(st) == 'table' and (st.status or st.state or st.phase) or st)
        if type(st) == 'table' and st.err ~= nil then parts[#parts + 1] = 'stage_err=' .. tostring(st.err) end
    end
    if p.component ~= nil then parts[#parts + 1] = 'component=' .. tostring(p.component) end
    if p.err ~= nil then parts[#parts + 1] = 'err=' .. describe_job_value(p.err) end
    if p.error ~= nil then parts[#parts + 1] = 'error=' .. describe_job_value(p.error) end
    if p.reason ~= nil then parts[#parts + 1] = 'reason=' .. describe_job_value(p.reason) end
    return table.concat(parts, ' ')
end

local function wait_job_chatty(conn, job_id, state, timeout, progress_fn)
    timeout = timeout or 4.0
    local topic = update_topics.workflow_update_job(job_id)
    local view = conn:retained_view(topic)
    local deadline = fibers.now() + timeout
    local last_log = -math.huge

    local function maybe_log(force)
        local now = fibers.now()
        if not force and (now - last_log) < WAIT_PROGRESS_LOG_S then return end
        last_log = now
        local msg = view:get(topic)
        local payload = msg and msg.payload or nil
        local extra = progress_fn and progress_fn() or ''
        if extra ~= '' then extra = '; ' .. extra end
        log(('waiting for job %s -> %s: %s%s'):format(job_id, state, describe_job_progress(payload), extra))
    end

    local payload = (view:get(topic) or {}).payload
    if payload and payload.state == state then
        view:close()
        return payload
    end
    maybe_log(true)

    local seen = view:version()
    while true do
        local remaining = deadline - fibers.now()
        if remaining <= 0 then
            maybe_log(true)
            view:close()
            error('timed out waiting for update job ' .. tostring(job_id) .. ' ' .. tostring(state), 0)
        end

        local which, version, reason = fibers.perform(op.named_choice({
            changed = view:changed_op(seen),
            progress = sleep.sleep_op(math.min(WAIT_PROGRESS_LOG_S, remaining)),
        }))

        if which == 'changed' then
            if version == nil then
                view:close()
                error('update job ' .. tostring(job_id) .. ' closed: ' .. tostring(reason or 'closed'), 0)
            end
            seen = version
            payload = (view:get(topic) or {}).payload
            if payload and payload.state == state then
                maybe_log(true)
                view:close()
                return payload
            end
        end

        maybe_log(which == 'changed')
    end
end

local function wait_component_software(conn, image_id, boot_id)
    return wait_retained_payload_where(conn, device_topics.component_software('mcu'), 'mcu software canonical state', function (p)
        if p and (image_id == nil or p.image_id == image_id) and (boot_id == nil or p.boot_id == boot_id) then return p end
        return nil
    end, { timeout = 4.0 })
end

local function start_public_fabric(scope, conn, cfg, transport, opts)
    opts = opts or {}
    local link_overrides = opts.link_overrides
    if link_overrides == nil and transport ~= nil then
        link_overrides = {
            ['link-a'] = {
                open_transport_op = function () return wrap_session_op(transport.session) end,
                transfer = opts.transfer,
            },
        }
    end
    local ok, err = scope:spawn(function ()
        fabric.start(conn, {
            name = opts.name or 'fabric',
            env = 'test',
            config = cfg,
            link_overrides = link_overrides,
        })
    end)
    assert_true(ok, tostring(err))
end

local function fabric_config(local_node, peer_node, bridge, transfer)
    return {
        schema = fabric.config.SCHEMA,
        local_node = local_node,
        links = {
            {
                id = 'link-a',
                peer_id = peer_node,
                transport = { source = 'test', class = 'jsonl', id = 'link-a' },
                session = { hello_interval_s = 5.0, ping_interval_s = 5.0, liveness_timeout_s = 5.0 },
                bridge = bridge or {},
                transfer = transfer or { chunk_size = 2048, timeout_s = 3.0 },
            },
        },
    }
end

local function cm5_fabric_config()
    return fabric_config('cm5', 'mcu', {
        imports = {
            { id = 'mcu-state', remote = { 'state', 'self' }, ['local'] = { 'raw', 'member', 'mcu', 'state' } },
            { id = 'mcu-event', remote = { 'event', 'self' }, ['local'] = { 'raw', 'member', 'mcu', 'cap', 'telemetry', 'main', 'event' } },
            { id = 'mcu-cap', remote = { 'cap', 'self' }, ['local'] = { 'raw', 'member', 'mcu', 'cap' } },
        },
        rpc = {
            outbound = {
                {
                    id = 'mcu-prepare',
                    ['local'] = { 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'rpc', 'prepare-update' },
                    remote = { 'cap', 'self', 'updater', 'main', 'rpc', 'prepare-update' },
                    timeout_s = 2.0,
                },
                {
                    id = 'mcu-commit',
                    ['local'] = { 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'rpc', 'commit-update' },
                    remote = { 'cap', 'self', 'updater', 'main', 'rpc', 'commit-update' },
                    timeout_s = 2.0,
                },
            },
        },
    }, { chunk_size = 2048, timeout_s = REALISTIC_TRANSFER_TIMEOUT_S })
end

local function mcu_fabric_config()
    return fabric_config('mcu', 'cm5', {
        exports = {
            { id = 'mcu-state-export', ['local'] = { 'state', 'self' }, remote = { 'state', 'self' }, publish = true, retain = true },
            { id = 'mcu-cap-export', ['local'] = { 'cap', 'self' }, remote = { 'cap', 'self' }, publish = true, retain = true },
        },
        rpc = {
            inbound = {
                {
                    id = 'mcu-prepare-in',
                    ['local'] = { 'cap', 'self', 'updater', 'main', 'rpc', 'prepare-update' },
                    remote = { 'cap', 'self', 'updater', 'main', 'rpc', 'prepare-update' },
                    timeout_s = 2.0,
                },
                {
                    id = 'mcu-commit-in',
                    ['local'] = { 'cap', 'self', 'updater', 'main', 'rpc', 'commit-update' },
                    remote = { 'cap', 'self', 'updater', 'main', 'rpc', 'commit-update' },
                    timeout_s = 2.0,
                },
            },
        },
    }, { chunk_size = 2048, timeout_s = REALISTIC_TRANSFER_TIMEOUT_S })
end

local function publish_mcu_facts(conn, fake)
    local image = fake.committed_image_id or fake.old_image_id
    local boot = 'mcu-boot-' .. tostring(fake.boot_seq)
    conn:retain({ 'state', 'self', 'software' }, {
        image_id = image,
        boot_id = boot,
        version = image,
    })
    conn:retain({ 'state', 'self', 'updater' }, {
        state = 'ready',
        last_error = nil,
        staged_image_id = fake.staged and fake.staged.image_id or nil,
        pending_image_id = fake.committed_image_id,
        job_id = fake.job_id,
    })
    conn:retain({ 'cap', 'self', 'updater', 'main', 'meta' }, {
        class = 'updater',
        id = 'main',
        methods = { 'prepare-update', 'commit-update' },
    })
    conn:retain({ 'cap', 'self', 'updater', 'main', 'status' }, {
        available = true,
        state = 'available',
    })
end

local function new_mcu_receive_target(fake)
    local target = {}
    function target:open_sink_op(req)
        fake.transfer_begin = req
        fake.receive_started_at = fibers.now()
        fake.receive_bytes = 0
        fake.receive_chunks = 0
        fake.receive_next_log = MCU_PROGRESS_LOG_BYTES
        assert_eq(req.target, 'updater/main')
        log(('MCU receive target opened: target=%s size=%s job_id=%s image_id=%s'):format(
            tostring(req.target),
            tostring(req.size),
            tostring(req.meta and req.meta.job_id),
            tostring(req.meta and (req.meta.image_id or req.meta.expected_image_id))
        ))
        local chunks = {}
        local sink = {}
        function sink:append_op(chunk)
            return fibers.run_scope_op(function ()
                -- Simulate a small flash/programming delay on the MCU side.
                -- This keeps the receiver honest without changing the transfer
                -- protocol: it still only asks for the current offset.
                fibers.perform(sleep.sleep_op(MCU_FLASH_WRITE_DELAY_S))
                chunks[#chunks + 1] = chunk
                fake.receive_bytes = (fake.receive_bytes or 0) + #(chunk or '')
                fake.receive_chunks = (fake.receive_chunks or 0) + 1
                if fake.receive_bytes >= (fake.receive_next_log or MCU_PROGRESS_LOG_BYTES) then
                    local elapsed = fibers.now() - (fake.receive_started_at or fibers.now())
                    log(('MCU received %d bytes in %d chunks after %.1fs'):format(
                        fake.receive_bytes, fake.receive_chunks or 0, elapsed
                    ))
                    fake.receive_next_log = fake.receive_bytes + MCU_PROGRESS_LOG_BYTES
                end
                return true, nil
            end):wrap(function (status, _report, ok, err)
                if status ~= 'ok' then return nil, err or status end
                return ok, err
            end)
        end
        function sink:commit_op(req2)
            local bytes = table.concat(chunks)
            log(('MCU transfer commit: %d bytes in %d chunks; digest=%s'):format(
                #bytes, fake.receive_chunks or 0, tostring(req2.digest)
            ))
            fake.staged = {
                bytes = bytes,
                digest = req2.digest,
                size = req2.size,
                image_id = req.meta and (req.meta.image_id or req.meta.expected_image_id),
                job_id = req.meta and req.meta.job_id,
            }
            fake.staged_signal = (fake.staged_signal or 0) + 1
            return fibers.always({ staged = true, digest = req2.digest }, nil)
        end
        function sink:abort(reason)
            fake.abort_reason = reason
            fake.abort_count = (fake.abort_count or 0) + 1
            log(('MCU transfer abort: reason=%s after %d bytes in %d chunks'):format(
                tostring(reason), fake.receive_bytes or 0, fake.receive_chunks or 0
            ))
            return true, nil
        end
        return fibers.always(sink, nil)
    end
    return target
end

local function start_fake_mcu(scope, bus, fake)
    local conn = bus:connect({ origin_base = { service = 'fake-mcu' } })
    fake.boot_seq = (fake.boot_seq or 0) + 1
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
            req:reply({ ready = true, target = 'updater/main', max_chunk_size = 2048 })
        end
    end))

    assert_true(scope:spawn(function ()
        while true do
            local req = fibers.perform(commit_ep:recv_op())
            if req == nil then return end
            fake.commit_payload = req.payload
            assert_eq(type(req.payload), 'table')
            assert_eq(req.payload.job_id, fake.job_id)
            assert_eq(req.payload.metadata, nil)
            fake.commit_seen = true
            fake.committed_image_id = (fake.staged and fake.staged.image_id)
                or (type(req.payload) == 'table' and req.payload.expected_image_id)
            conn:retain({ 'state', 'self', 'updater' }, {
                state = 'rebooting',
                last_error = nil,
                pending_image_id = fake.committed_image_id,
                staged_image_id = fake.staged and fake.staged.image_id or nil,
                job_id = fake.job_id,
            })
            req:reply({ accepted = true, reboot_required = true })
        end
    end))

    return conn
end

local function new_fabric_client(conn)
    local client = {}
    function client:send_blob_op(params, opts)
        params = params or {}
        opts = opts or {}
        assert(params.source_owner, 'fabric client source_owner required')
        return conn:call_op(fabric_topics.transfer_manager_rpc('send-blob'), {
            link_id = params.link_id or 'link-a',
            request_id = params.request_id or ('device-stage-' .. tostring(params.job_id or os.clock())),
            xfer_id = params.xfer_id,
            target = assert(params.target, 'fabric client params.target required'),
            source_owner = params.source_owner,
            size = params.size,
            digest_alg = params.digest_alg,
            digest = params.digest,
            chunk_size = params.chunk_size or 2048,
            meta = params.meta,
            timeout_s = opts.timeout or params.timeout or REALISTIC_TRANSFER_TIMEOUT_S,
        }, { timeout = opts.timeout or params.timeout or REALISTIC_TRANSFER_TIMEOUT_S }):wrap(function (reply, err)
            if reply == nil then return nil, err end
            return {
                ok = reply.ok,
                committed = reply.committed,
                transfer = reply,
            }, nil
        end)
    end
    return client
end

local function update_config(opts)
    opts = opts or {}
    return {
        schema = 'devicecode.update/1',
        components = {
            {
                component = 'mcu',
                -- Active update owns the phase budget.  The Update backend
                -- opens the Device bus call without lua-bus' default timeout;
                -- active_job.stage composes the backend Op with this deadline.
                stage_timeout_s = opts.stage_timeout_s or REALISTIC_TRANSFER_TIMEOUT_S,
            },
        },
    }
end

local function device_config(opts)
    opts = opts or {}
    local stage_timeout_s = opts.stage_action_timeout_s or REALISTIC_TRANSFER_TIMEOUT_S
    return {
        schema = 'devicecode.config/device/1',
        components = {
            mcu = {
                class = 'member',
                subtype = 'mcu',
                role = 'controller',
                member = 'mcu',
                required_facts = { 'software', 'updater' },
                facts = mcu_schema.member_fact_topics('mcu'),
                events = mcu_schema.member_event_topics('mcu'),
                actions = {
                    ['restart'] = { kind = 'rpc', call_topic = device_topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') },
                    ['prepare-update'] = {
                        kind = 'rpc',
                        call_topic = device_topics.raw_member_cap_rpc('mcu', 'updater', 'main', 'prepare-update'),
                        timeout_s = 2.0,
                    },
                    ['stage-update'] = {
                        kind = 'fabric_stage',
                        target = 'updater/main',
                        chunk_size = 2048,
                        artifact_store = 'main',
                        -- This is Device action policy, not a hidden bus timeout.
                        -- Keep it in the component config so the test does not
                        -- change Device's global default action timeout.
                        timeout_s = stage_timeout_s,
                    },
                    ['commit-update'] = {
                        kind = 'rpc',
                        call_topic = device_topics.raw_member_cap_rpc('mcu', 'updater', 'main', 'commit-update'),
                        timeout_s = 2.0,
                    },
                },
            },
        },
    }
end

local function hal_config(roots)
    return {
        schema = 'devicecode.config/hal/1',
        artifact_store = {
            stores = {
                {
                    id = 'main',
                    transient_root = roots.artifact.transient,
                    durable_root = roots.artifact.durable,
                    import_root = roots.artifact.import,
                    durable_enabled = true,
                },
            },
        },
        control_store = {
            { name = 'update', root = roots.control },
        },
    }
end

local function start_hal(scope, bus, roots)
    local conn = bus:connect({ origin_base = { service = 'hal' } })
    if posix_ok and stdlib and stdlib.setenv then
        stdlib.setenv('DEVICECODE_CONFIG_DIR', roots.config, true)
    end
    assert_true(scope:spawn(function ()
        hal_service.start(conn, { name = 'hal', env = 'test', heartbeat_s = false })
    end))
    conn:retain({ 'cfg', 'hal' }, { data = hal_config(roots) })
    wait_retained_payload_where(conn, { 'cap', 'artifact-store', 'main', 'status' }, 'artifact-store available', function (p)
        return p and p.available == true and p
    end, { timeout = 4.0 })
    wait_retained_payload_where(conn, { 'cap', 'control-store', 'update', 'status' }, 'control-store available', function (p)
        return p and p.available == true and p
    end, { timeout = 4.0 })
    return conn
end

local function start_http(scope, bus)
    local conn = bus:connect({ origin_base = { service = 'http' } })
    assert_true(scope:spawn(function (s)
        http_service.run(s, {
            conn = conn,
            id = 'main',
            config = {
                schema = 'devicecode.config/http/1',
                id = 'main',
                policy = { allow_loopback = true, max_request_body = 16 * 1024 * 1024, max_response_body = 16 * 1024 * 1024 },
            },
            backend_timeout = 3.0,
            connection_setup_timeout = 3.0,
            intra_stream_timeout = 3.0,
        })
    end))
    wait_retained_payload_where(conn, { 'cap', 'http', 'main', 'status' }, 'http service available', function (p)
        return p and p.available == true and p
    end, { timeout = 4.0 })
    return conn
end

local function start_device(scope, bus, fabric_client, opts)
    opts = opts or {}
    local conn = bus:connect({ origin_base = { service = 'device' } })
    assert_true(scope:spawn(function (s)
        device_service.run(s, {
            conn = conn,
            initial_config = device_config(opts),
            fabric_client = fabric_client,
            watch_config = false,
        })
    end))
    wait_retained_payload_where(conn, device_topics.component_cap_status('mcu'), 'mcu component cap available', function (p)
        return p and p.available == true and p
    end, { timeout = 4.0 })
    return conn
end

local function start_update(scope, bus, opts)
    opts = opts or {}
    local conn = bus:connect({ origin_base = { service = 'update' } })
    assert_true(scope:spawn(function (s)
        update_service.run(s, {
            conn = conn,
            service_id = 'update',
            watch_config = false,
            config = update_config(opts),
            job_store_call_opts = { timeout = 3.0 },
        })
    end))
    wait_retained_payload_where(conn, update_topics.update_manager_status(), 'update manager available', function (p)
        return p and p.available == true and p
    end, { timeout = 4.0 })
    wait_retained_payload_where(conn, update_topics.artifact_ingest_status(), 'artifact ingest available', function (p)
        return p and p.available == true and p
    end, { timeout = 4.0 })
    return conn
end

local function start_ui(scope, bus, port, roots)
    local conn = bus:connect({ origin_base = { service = 'ui' } })
    assert_true(scope:spawn(function (s)
        ui_service.run(s, {
            conn = conn,
            service_id = 'ui',
            auth_opts = {
                users = {
                    tester = { password = 'test-password', principal = { kind = 'user', id = 'tester' } },
                },
            },
            bus = bus,
            connect = function (principal)
                return bus:connect({ principal = principal or { kind = 'ui-test' } })
            end,
            encode_json = function (v) return assert(cjson.encode(v)) end,
            update = {
                bus = bus,
                component = 'mcu',
                ingest_id = 'ing-mcu-http-uart',
                job_id = 'job-mcu-http-uart',
                create_job = true,
                start_job = true,
                timeout = 8.0,
                chunk_size = 4096,
                metadata = {
                    source = 'browser',
                    format = 'dcmcu-v1',
                },
            },
            updates = { upload = { enabled = true, max_bytes = 1024 * 1024, require_auth = false, component = 'mcu', create_job = true, start_job = true }, commit = { require_auth = false } },
        })
    end))
    conn:retain({ 'cfg', 'ui' }, { data = {
        schema = 'devicecode.config/ui/1',
        enabled = true,
        http = { enabled = true, cap_id = 'main', host = '127.0.0.1', port = port, max_active_requests = 8 },
        static = { root = roots.static, index = 'index.html' },
        updates = { upload = { enabled = true, max_bytes = 1024 * 1024, require_auth = false, component = 'mcu', create_job = true, start_job = true }, commit = { require_auth = false } },
        sse = { enabled = false },
        sessions = { prune_interval = false },
    } })
    wait_retained_payload_where(conn, http_topics.state('main', 'stats'), 'ui listener active', function (p)
        return p and type(p.active_listeners) == 'number' and p.active_listeners > 0 and p
    end, { timeout = 4.0 })
    return conn
end

local function make_realistic_mcu_blob(image_id, target_bytes)
    target_bytes = target_bytes or REALISTIC_MCU_BLOB_BYTES
    local payload = string.rep('payload-0123456789abcdef-', math.ceil(target_bytes / 24)):sub(1, target_bytes)
    return dcmcu_fixture.make(image_id or 'mcu-image-new', payload, {
        payload_sha256 = sha256_hex_string(payload),
    })
end

local function write_all(stream, data)
    local off = 1
    while off <= #data do
        local n, err = fibers.perform(stream:write_op(data:sub(off)))
        if n == nil then return nil, err or 'write_failed' end
        if n <= 0 then return nil, 'zero_length_write' end
        off = off + n
    end
    return true, nil
end


local function fault_for_direction(stats, direction)
    local faults = type(stats.faults) == 'table' and stats.faults or {}
    return type(faults[direction]) == 'table' and faults[direction] or {}
end

local function maybe_inject_malformed_jsonl(direction, output, stats)
    local f = fault_for_direction(stats, direction)
    local default_direction = stats.default_malformed_direction or 'cm5_to_mcu'
    if f.disable_malformed == true then return true, nil end
    if f.malformed_line_count == nil and direction ~= default_direction then return true, nil end
    local max_lines = f.malformed_line_count or stats.malformed_line_count or UART_MALFORMED_LINE_COUNT
    local key = 'malformed_lines_' .. direction
    if (stats[key] or 0) >= max_lines then return true, nil end
    local next_key = 'next_malformed_at_' .. direction
    local next_at = stats[next_key] or f.malformed_line_first_at or stats.malformed_line_first_at or UART_MALFORMED_LINE_FIRST_AT
    if (stats.bytes or 0) < next_at then return true, nil end

    stats.malformed_lines = (stats.malformed_lines or 0) + 1
    stats[key] = (stats[key] or 0) + 1
    stats[next_key] = next_at + (f.malformed_line_every_bytes or stats.malformed_line_every_bytes or UART_MALFORMED_LINE_EVERY_BYTES)
    local line = ('{ malformed json from mcu_http_uart test #%d on %s }\n'):format(stats.malformed_lines, direction)
    local ok, err = write_all(output.master, line)
    if ok ~= true then return nil, err or 'malformed_jsonl_inject_failed' end

    stats.bytes = (stats.bytes or 0) + #line
    stats.fragments = (stats.fragments or 0) + 1
    stats.malformed_bytes = (stats.malformed_bytes or 0) + #line
    log(('UART middleware injected standalone malformed JSONL line #%d on %s at %d bytes'):format(
        stats.malformed_lines, direction, stats.bytes
    ))
    return true, nil
end

local function apply_uart_faults(direction, stats, piece)
    local f = fault_for_direction(stats, direction)
    if type(piece) ~= 'string' or piece == '' then return piece end

    local dir_bytes = type(stats.bytes_by_direction) == 'table' and (stats.bytes_by_direction[direction] or 0) or 0
    local function crosses(after)
        return type(after) == 'number' and dir_bytes < after and (dir_bytes + #piece) >= after
    end

    if f.pause_once_after_bytes and not f.pause_once_done and crosses(f.pause_once_after_bytes) then
        f.pause_once_done = true
        local pause_s = f.pause_s or 0.75
        stats.fault_pauses = (stats.fault_pauses or 0) + 1
        log(('UART middleware fault pause #%d on %s for %.3fs at %d direction-bytes'):format(
            stats.fault_pauses, direction, pause_s, dir_bytes
        ))
        fibers.perform(sleep.sleep_op(pause_s))
    end

    if f.drop_byte_after_bytes and not f.drop_byte_done and crosses(f.drop_byte_after_bytes) then
        local rel = math.max(1, math.min(#piece, f.drop_byte_after_bytes - dir_bytes))
        f.drop_byte_done = true
        stats.dropped_bytes = (stats.dropped_bytes or 0) + 1
        log(('UART middleware dropped byte #%d on %s at stream byte %d rel=%d'):format(
            stats.dropped_bytes, direction, f.drop_byte_after_bytes, rel
        ))
        piece = piece:sub(1, rel - 1) .. piece:sub(rel + 1)
    end

    local newline_after = f.drop_next_newline_after_bytes or f.drop_newline_after_bytes
    if newline_after and not f.drop_newline_done then
        if not f.drop_newline_armed and ((type(newline_after) ~= 'number') or (dir_bytes + #piece) >= newline_after) then
            f.drop_newline_armed = true
            log(('UART middleware armed next-newline drop on %s after %s direction-bytes'):format(
                direction, tostring(newline_after)
            ))
        end
        if f.drop_newline_armed then
            local nl = piece:find('\n', 1, true)
            if nl ~= nil then
                f.drop_newline_done = true
                stats.dropped_newlines = (stats.dropped_newlines or 0) + 1
                log(('UART middleware dropped newline #%d on %s after threshold %s rel=%d'):format(
                    stats.dropped_newlines, direction, tostring(newline_after), nl
                ))
                piece = piece:sub(1, nl - 1) .. piece:sub(nl + 1)
            end
        end
    end

    return piece
end

local function write_uart_fragment_piece(direction, output, stats, piece)
    if piece == '' then return true, nil end
    piece = apply_uart_faults(direction, stats, piece)
    if piece == '' then return true, nil end
    local ok, werr = write_all(output.master, piece)
    if ok ~= true then
        return nil, werr or 'write_failed'
    end
    stats.bytes = (stats.bytes or 0) + #piece
    stats.bytes_by_direction = stats.bytes_by_direction or {}
    stats.bytes_by_direction[direction] = (stats.bytes_by_direction[direction] or 0) + #piece
    stats.fragments = (stats.fragments or 0) + 1

    if piece:sub(-1) == '\n' then
        local mok, merr = maybe_inject_malformed_jsonl(direction, output, stats)
        if mok ~= true then return nil, merr end
    end

    return true, nil
end

local function relay_fragmented_uart(direction, input, output, stats)
    while true do
        local want = math.random(1, UART_MAX_READ_BYTES)
        local chunk, err = fibers.perform(input.master:read_some_op(want))
        if chunk == nil then
            return { direction = direction, reason = err or 'closed' }
        end

        local off = 1
        while off <= #chunk do
            local frag_len = math.random(1, UART_MAX_FRAGMENT_BYTES)
            local frag = chunk:sub(off, off + frag_len - 1)
            local frag_off = 1
            while frag_off <= #frag do
                local nl = frag:find('\n', frag_off, true)
                local piece
                if nl ~= nil then
                    piece = frag:sub(frag_off, nl)
                    frag_off = nl + 1
                else
                    piece = frag:sub(frag_off)
                    frag_off = #frag + 1
                end
                local ok, werr = write_uart_fragment_piece(direction, output, stats, piece)
                if ok ~= true then
                    return { direction = direction, reason = werr or 'write_failed' }
                end
            end
            off = off + #frag

            if stats.bytes >= (stats.next_long_pause_at or UART_LONG_PAUSE_EVERY_BYTES) then
                stats.pauses = (stats.pauses or 0) + 1
                stats.next_long_pause_at = (stats.next_long_pause_at or UART_LONG_PAUSE_EVERY_BYTES) + UART_LONG_PAUSE_EVERY_BYTES
                local pause_s = UART_LONG_PAUSE_BASE_S + (math.random() * UART_LONG_PAUSE_JITTER_S)
                log(('UART middleware pause #%d on %s for %.3fs at %d bytes'):format(
                    stats.pauses, direction, pause_s, stats.bytes
                ))
                fibers.perform(sleep.sleep_op(pause_s))
            end

            -- Approximate 115200 8N1 UART payload rate, with modest scheduling
            -- jitter and short fragments.  This tests the release protocol under
            -- realistic pacing without injecting corrupt or reordered bytes.
            fibers.perform(sleep.sleep_op((#frag / UART_BYTES_PER_SEC) + (math.random(0, 4) / 1000)))
        end
    end
end

local function start_noisy_uart_middleware(scope, cm5_port, mcu_port, opts)
    opts = opts or {}
    local stats = {
        bytes = 0,
        fragments = 0,
        pauses = 0,
        malformed_lines = 0,
        malformed_bytes = 0,
        dropped_bytes = 0,
        dropped_newlines = 0,
        fault_pauses = 0,
        next_long_pause_at = opts.long_pause_every_bytes or UART_LONG_PAUSE_EVERY_BYTES,
        malformed_line_count = opts.malformed_line_count,
        malformed_line_first_at = opts.malformed_line_first_at,
        malformed_line_every_bytes = opts.malformed_line_every_bytes,
        default_malformed_direction = opts.default_malformed_direction,
        faults = opts.faults or {},
        bytes_by_direction = {},
    }
    local ok_a, err_a = scope:spawn(function ()
        return relay_fragmented_uart('cm5_to_mcu', cm5_port, mcu_port, stats)
    end)
    assert_true(ok_a, tostring(err_a))
    local ok_b, err_b = scope:spawn(function ()
        return relay_fragmented_uart('mcu_to_cm5', mcu_port, cm5_port, stats)
    end)
    assert_true(ok_b, tostring(err_b))
    return stats
end

local function open_pty_transport_op(slave_name)
    return op.guard(function ()
        local stream, err = pty.open_slave_stream(slave_name)
        if not stream then return fibers.always(nil, err or 'pty_slave_open_failed') end
        local transport, terr = hal_transport.wrap_transport(stream, { terminator = '\n' })
        if not transport then
            if type(stream.terminate) == 'function' then stream:terminate(terr or 'transport_wrap_failed') end
            return fibers.always(nil, terr or 'transport_wrap_failed')
        end
        return fibers.always(transport, nil)
    end)
end

local function cm5_uart_fabric_config()
    local cfg = cm5_fabric_config()
    cfg.links[1].transport = {
        source = 'uart_manager',
        class = 'uart',
        id = 'uart0',
        terminator = '\n',
    }
    cfg.links[1].session.hello_interval_s = 0.20
    return cfg
end

local function mcu_pty_fabric_config()
    local cfg = mcu_fabric_config()
    cfg.links[1].session.hello_interval_s = 0.20
    return cfg
end

local function start_fabric_pair(parent_scope, cm5_bus, fake, uart, opts)
    opts = opts or {}
    local pair_scope = assert(parent_scope:child())
    local stats = start_noisy_uart_middleware(pair_scope, assert(uart and uart.cm5, 'cm5 PTY required'), assert(uart and uart.mcu, 'mcu PTY required'), opts.uart)

    local cm5_conn = cm5_bus:connect({ origin_base = { service = 'fabric-cm5' } })

    -- CM5 uses the real HAL raw-host UART capability path.  The MCU side is a
    -- separate Lua process with its own bus, scheduler and HAL UART manager.
    start_public_fabric(pair_scope, cm5_conn, cm5_uart_fabric_config(), nil, { name = 'fabric-cm5' })

    wait_retained_payload_where(cm5_conn, fabric_topics.transfer_manager_status(), 'cm5 fabric transfer manager available', function (p)
        return p and p.available == true and p
    end, { timeout = 6.0 })

    local cm5_session = wait_fabric_session_established(cm5_conn, 'CM5 fabric hello/hello_ack session established', { timeout = 6.0 })
    local cm5_snapshot = fabric_payload_snapshot(cm5_session) or {}
    assert_eq(cm5_snapshot.peer_node, 'mcu', 'CM5 fabric session should identify MCU peer')
    if not (fake and fake.expect_mcu_fabric_event == false) then
        wait_until_test('MCU child fabric hello/hello_ack session established', function ()
            return fake and fake.mcu_fabric_session_seen == true
        end, 6.0, 0.05)
        assert_eq(fake.mcu_fabric_session and fake.mcu_fabric_session.peer_node, 'cm5', 'MCU fabric session should identify CM5 peer')
    end
    log_fabric_status(cm5_conn, 'CM5 fabric established status')

    return {
        scope = pair_scope,
        cm5_conn = cm5_conn,
        uart_stats = stats,
    }
end

local function stop_fabric_pair(pair, reason)
    if not pair then return end
    if pair.scope then
        pair.scope:cancel(reason or 'fabric pair stop')
        fibers.perform(pair.scope:join_op())
    end
    if pair.cm5_conn then bus_cleanup.disconnect(pair.cm5_conn) end
    if pair.mcu_conn then bus_cleanup.disconnect(pair.mcu_conn) end
end

local function start_cm5_instance(parent_scope, roots, http_port, uart_port, opts)
    opts = opts or {}
    local scope = assert(parent_scope:child())
    local bus = busmod.new()
    local conn = bus:connect({ origin_base = { service = 'test-cm5' } })

    -- The test UART adapter registers finalisers on the instance scope.
    -- Do this before starting services that spawn onto the same scope; after a
    -- scope has started, lua-fibers requires finalisers to be added from within
    -- that target scope.
    if uart_port ~= nil then
        start_cm5_uart_manager(scope, bus, uart_port)
    end
    start_hal(scope, bus, roots)
    start_http(scope, bus)

    return {
        scope = scope,
        bus = bus,
        conn = conn,
        start_services_after_fabric = function (fabric_client)
            start_device(scope, bus, fabric_client, opts.device or opts)
            start_update(scope, bus, opts.update or opts)
            if http_port then start_ui(scope, bus, http_port, roots) end
        end,
    }
end

local function update_fake_from_mcu_child(fake, ev)
    if type(ev) ~= 'table' then return end
    local event = ev.event
    if event == 'ready' then
        fake.boot_seq = ev.boot_seq or fake.boot_seq
        fake.child_ready = true
        fake.child_pid = ev.pid
        log(('MCU child ready: pid=%s boot_seq=%s image=%s'):format(
            tostring(ev.pid), tostring(ev.boot_seq), tostring(ev.image_id)
        ))
    elseif event == 'receive_opened' then
        fake.transfer_begin = ev
        fake.receive_started_at = fibers.now()
        fake.receive_bytes = 0
        fake.receive_chunks = 0
        log(('MCU receive target opened: target=%s size=%s job_id=%s image_id=%s'):format(
            tostring(ev.target), tostring(ev.size), tostring(ev.job_id), tostring(ev.image_id)
        ))
    elseif event == 'receive_tick' then
        fake.receive_bytes = ev.bytes or fake.receive_bytes
        fake.receive_chunks = ev.chunks or fake.receive_chunks
    elseif event == 'receive_progress' then
        fake.receive_bytes = ev.bytes or fake.receive_bytes
        fake.receive_chunks = ev.chunks or fake.receive_chunks
        log(('MCU received %d bytes in %d chunks after %.1fs'):format(
            fake.receive_bytes or 0, fake.receive_chunks or 0, tonumber(ev.elapsed_s) or 0
        ))
    elseif event == 'transfer_commit' then
        fake.receive_bytes = ev.size or fake.receive_bytes
        fake.receive_chunks = ev.chunks or fake.receive_chunks
        fake.staged = {
            size = ev.size,
            digest = ev.digest,
            payload_digest = ev.payload_digest,
            image_id = ev.image_id,
            job_id = ev.job_id,
        }
        fake.staged_signal = (fake.staged_signal or 0) + 1
        log(('MCU transfer commit: %d bytes in %d chunks; digest=%s payload_digest=%s'):format(
            ev.size or 0, ev.chunks or 0, tostring(ev.digest), tostring(ev.payload_digest)
        ))
    elseif event == 'transfer_abort' then
        fake.abort_reason = ev.reason
        fake.abort_count = ev.abort_count or ((fake.abort_count or 0) + 1)
        fake.receive_bytes = ev.bytes or fake.receive_bytes
        fake.receive_chunks = ev.chunks or fake.receive_chunks
        log(('MCU transfer abort: reason=%s after %d bytes in %d chunks'):format(
            tostring(ev.reason), fake.receive_bytes or 0, fake.receive_chunks or 0
        ))
    elseif event == 'prepare' then
        fake.prepare_payload = ev.payload
        fake.job_id = ev.job_id
    elseif event == 'commit' then
        fake.commit_payload = ev.payload
        fake.commit_seen = true
        fake.committed_image_id = ev.committed_image_id
    elseif event == 'rebooting' then
        fake.commit_seen = true
        fake.rebooting_seen = true
        fake.committed_image_id = ev.image_id or fake.committed_image_id
        log(('MCU child rebooting: image=%s version=%s length=%s'):format(
            tostring(ev.image_id), tostring(ev.version), tostring(ev.length)
        ))
    elseif event == 'fabric_session' then
        fake.mcu_fabric_session = ev
        fake.mcu_fabric_session_seen = true
        log(('MCU child fabric session: phase=%s established=%s peer_node=%s peer_sid=%s gen=%s wire_errors=%s bad_frames=%s'):format(
            tostring(ev.phase), tostring(ev.established), tostring(ev.peer_node), tostring(ev.peer_sid),
            tostring(ev.session_generation), tostring(ev.wire_errors or 0), tostring(ev.bad_frame_count or 0)
        ))
    elseif event == 'fabric_status' then
        log(('MCU child fabric %s: %s'):format(tostring(ev.component or ev.label or 'status'), tostring(ev.summary)))
    elseif event == 'log' then
        log('MCU child: ' .. tostring(ev.message))
    end
end

local function start_mcu_instance(parent_scope, fake, uart_port)
    assert(uart_port and uart_port.slave_name, 'MCU PTY slave required')
    fake.mcu_fabric_session_seen = false
    fake.mcu_fabric_session = nil
    local scope = assert(parent_scope:child())
    local ipc_path = ('/tmp/devicecode-mcu-child-%d-%d.sock'):format(os.time(), math.random(100000, 999999))
    os.remove(ipc_path)

    local server, serr = socket.listen_unix(ipc_path, { ephemeral = true })
    assert_not_nil(server, serr or 'listen_unix failed')
    local ready_ch = channel.new(1)

    scope:finally(function ()
        safe.pcall(function () server:close() end)
        os.remove(ipc_path)
    end)

    assert_true(scope:spawn(function ()
        local stream, aerr = server:accept()
        if not stream then
            ready_ch:put({ ok = false, err = aerr or 'mcu child ipc accept failed' })
            return
        end
        while true do
            local line, rerr = fibers.perform(stream:read_line_op())
            if line == nil then
                if fake.child_ready ~= true then
                    ready_ch:put({ ok = false, err = rerr or 'mcu child ipc closed before ready' })
                end
                return
            end
            local ev, derr = cjson.decode(line)
            if not ev then
                log('MCU child sent invalid IPC JSON: ' .. tostring(derr))
            else
                update_fake_from_mcu_child(fake, ev)
                if ev.event == 'ready' then
                    ready_ch:put({ ok = true })
                end
            end
        end
    end))

    local child_script = './integration/devhost/support/mcu_http_uart_child.lua'
    local cmd = exec.command({
        'lua', child_script,
        '--ipc', ipc_path,
        '--uart', uart_port.slave_name,
        '--old-image', fake.old_image_id or 'mcu-image-old',
        '--committed-image', fake.committed_image_id or '',
        '--boot-seq', tostring((fake.boot_seq or 0) + 1),
        cwd = '.',
        stdin = 'null',
        stdout = 'inherit',
        stderr = 'inherit',
        shutdown_grace = 1.0,
        env = {
            MCU_HTTP_UART_TRANSFER_TIMEOUT_S = tostring(REALISTIC_TRANSFER_TIMEOUT_S),
            MCU_HTTP_UART_FLASH_DELAY_S = tostring(MCU_FLASH_WRITE_DELAY_S),
        },
    })

    assert_true(scope:spawn(function ()
        local status, code, signal, err = fibers.perform(cmd:run_op())
        fake.child_exit = { status = status, code = code, signal = signal, err = err }
        if status ~= 'signalled' and not (status == 'exited' and code == 0) then
            log(('MCU child exited: status=%s code=%s signal=%s err=%s'):format(
                tostring(status), tostring(code), tostring(signal), tostring(err)
            ))
        end
    end))

    local ready = wait_channel_get(ready_ch, 6.0, 'MCU child ready')
    if not ready.ok then error(ready.err or 'MCU child failed to start', 0) end

    return { scope = scope, ipc_path = ipc_path, command = cmd }
end


local GO_DEVHOST_DEFAULT_REPO = 'https://github.com/jangala-dev/devicecode-go.git'
local GO_DEVHOST_DEFAULT_REF = 'rt-fixes'
local GO_DEVHOST_DEFAULT_CACHE = '/tmp/devicecode-go-devhost-cache'
local PICO2_AB_DEFAULT_REPO = 'https://github.com/jangala-dev/pico2-a-b.git'
local PICO2_AB_DEFAULT_REF = 'fabric'

local function go_devhost_download_enabled()
    local v = env_non_empty('DEVICECODE_GO_DOWNLOAD')
    return v == nil or v == '1' or v == 'true' or v == 'yes'
end

local function go_devhost_configured()
    return env_non_empty('MCU_DEVHOST_PTY_BIN') ~= nil
        or env_non_empty('DEVICECODE_GO_MCU_DEVHOST_PTY_BIN') ~= nil
        or env_non_empty('DEVICECODE_GO_ROOT') ~= nil
        or go_devhost_download_enabled()
end

local function safe_path_token(s)
    s = tostring(s or '')
    s = s:gsub('[^%w_.-]', '_')
    if s == '' then s = 'default' end
    return s
end

local function go_devhost_checkout_dir()
    local cache = env_non_empty('DEVICECODE_GO_CACHE') or GO_DEVHOST_DEFAULT_CACHE
    local ref = env_non_empty('DEVICECODE_GO_REF') or GO_DEVHOST_DEFAULT_REF
    return cache .. '/devicecode-go-' .. safe_path_token(ref)
end

local function pico2_ab_checkout_dir()
    local cache = env_non_empty('DEVICECODE_GO_CACHE') or GO_DEVHOST_DEFAULT_CACHE
    return cache .. '/pico2-a-b'
end

local function go_devhost_binary_path()
    local cache = env_non_empty('DEVICECODE_GO_CACHE') or GO_DEVHOST_DEFAULT_CACHE
    local ref = env_non_empty('DEVICECODE_GO_REF') or GO_DEVHOST_DEFAULT_REF
    return cache .. '/bin/mcu-devhost-pty-' .. safe_path_token(ref)
end

local function ensure_git_checkout(label, repo, ref, dir)
    local script = table.concat({
        'set -eu',
        'mkdir -p ' .. shquote(dir),
        'if [ ! -d ' .. shquote(dir .. '/.git') .. ' ]; then',
        '  rm -rf ' .. shquote(dir),
        '  mkdir -p ' .. shquote(dir),
        '  git -C ' .. shquote(dir) .. ' init -q',
        '  git -C ' .. shquote(dir) .. ' remote add origin ' .. shquote(repo),
        'fi',
        'git -C ' .. shquote(dir) .. ' fetch --depth 1 origin ' .. shquote(ref),
        'git -C ' .. shquote(dir) .. ' checkout -q --detach FETCH_HEAD',
        'git -C ' .. shquote(dir) .. ' reset -q --hard FETCH_HEAD',
        'git -C ' .. shquote(dir) .. ' clean -q -fdx',
    }, '\n')

    log(('go-pty: ensuring %s checkout repo=%s ref=%s dir=%s'):format(label, repo, ref, dir))
    local cmd = exec.command('sh', '-c', script)
    local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
    if not (st == 'exited' and code == 0) then
        return nil, ('%s checkout failed: status=%s code=%s signal=%s err=%s output=%s'):format(
            label, tostring(st), tostring(code), tostring(sig), tostring(err), tostring(out)
        )
    end
    return dir, nil
end

local function build_go_devhost_binary(go_dir)
    local bin = go_devhost_binary_path()
    local script = table.concat({
        'set -eu',
        'mkdir -p ' .. shquote((bin:gsub('/[^/]+$', ''))),
        'cd ' .. shquote(go_dir),
        'GOMAXPROCS=1 go build -o ' .. shquote(bin) .. ' ./cmd/mcu-devhost-pty',
    }, '\n')
    log(('go-pty: building Go MCU devhost binary path=%s'):format(bin))
    local cmd = exec.command('sh', '-c', script)
    local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
    if not (st == 'exited' and code == 0) then
        return nil, ('Go devhost build failed: status=%s code=%s signal=%s err=%s output=%s'):format(
            tostring(st), tostring(code), tostring(sig), tostring(err), tostring(out)
        )
    end
    return bin, nil
end

local function ensure_go_devhost_checkout()
    local root = env_non_empty('DEVICECODE_GO_ROOT')
    if root ~= nil then
        local bin, berr = build_go_devhost_binary(root)
        if not bin then return nil, berr end
        return root, bin, nil
    end
    if not go_devhost_download_enabled() then
        return nil, nil, 'set MCU_DEVHOST_PTY_BIN, DEVICECODE_GO_ROOT, or DEVICECODE_GO_DOWNLOAD=1 to run the Go devhost MCU PTY rig'
    end

    local go_repo = env_non_empty('DEVICECODE_GO_REPO') or GO_DEVHOST_DEFAULT_REPO
    local go_ref = env_non_empty('DEVICECODE_GO_REF') or GO_DEVHOST_DEFAULT_REF
    local go_dir = go_devhost_checkout_dir()

    local pico_repo = env_non_empty('DEVICECODE_PICO2_AB_REPO') or PICO2_AB_DEFAULT_REPO
    local pico_ref = env_non_empty('DEVICECODE_PICO2_AB_REF') or PICO2_AB_DEFAULT_REF
    local pico_dir = pico2_ab_checkout_dir()

    local dir, err = ensure_git_checkout('Go devhost', go_repo, go_ref, go_dir)
    if not dir then return nil, nil, err end

    -- devicecode-go's go.mod uses a local replacement for pico2-a-b at
    -- ../pico2-a-b. Keep that sibling checkout in the same cache root so
    -- the Lua repo does not need direct access to a monorepo workspace.
    local pdir, perr = ensure_git_checkout('pico2-a-b', pico_repo, pico_ref, pico_dir)
    if not pdir then return nil, nil, perr end

    local bin, berr = build_go_devhost_binary(go_dir)
    if not bin then return nil, nil, berr end

    return go_dir, bin, nil
end


local function resolve_go_devhost_provider()
    local bin = env_non_empty('MCU_DEVHOST_PTY_BIN') or env_non_empty('DEVICECODE_GO_MCU_DEVHOST_PTY_BIN')
    if bin ~= nil then
        return { bin = bin }, nil
    end
    if not command_available('go') then
        return nil, 'go is not installed'
    end
    local root = env_non_empty('DEVICECODE_GO_ROOT')
    if root ~= nil then
        local built_bin, berr = build_go_devhost_binary(root)
        if not built_bin then return nil, berr end
        return { bin = built_bin, cwd = root }, nil
    end
    if not go_devhost_download_enabled() then
        return nil, 'set MCU_DEVHOST_PTY_BIN, DEVICECODE_GO_ROOT, or DEVICECODE_GO_DOWNLOAD=1 to run the Go devhost MCU PTY rig'
    end
    if not command_available('git') then
        return nil, 'git is not installed'
    end
    local go_dir, built_bin, err = ensure_go_devhost_checkout()
    if not go_dir or not built_bin then
        return nil, err or 'Go devhost checkout/build unavailable'
    end
    return { bin = built_bin, cwd = go_dir }, nil
end

local function go_devhost_command_spec(uart_slave, state_dir, fake, opts)
    opts = opts or {}
    local provider = opts.provider
    local argv
    local cwd
    if provider ~= nil then
        argv = { provider.bin }
        cwd = provider.cwd
    else
        local bin = env_non_empty('MCU_DEVHOST_PTY_BIN') or env_non_empty('DEVICECODE_GO_MCU_DEVHOST_PTY_BIN')
        local root
        local root_err
        if bin ~= nil then
            argv = { bin }
        else
            local built_bin
            root, built_bin, root_err = ensure_go_devhost_checkout()
            if root == nil or built_bin == nil then return nil, root_err end
            argv = { built_bin }
            cwd = root
        end
    end
    argv[#argv + 1] = '--uart'; argv[#argv + 1] = uart_slave
    argv[#argv + 1] = '--state-dir'; argv[#argv + 1] = state_dir
    argv[#argv + 1] = '--node'; argv[#argv + 1] = opts.node or 'mcu'
    -- The devhost CM5 Fabric config in this test uses local_node='cm5'.
    -- Keep the Go peer expectation aligned with that test-local node name.
    argv[#argv + 1] = '--peer'; argv[#argv + 1] = opts.peer or 'cm5'
    argv[#argv + 1] = '--initial-image-id'; argv[#argv + 1] = fake.old_image_id or 'mcu-image-old'
    argv[#argv + 1] = '--initial-version'; argv[#argv + 1] = fake.old_version or '10.0'
    argv[#argv + 1] = '--initial-build-id'; argv[#argv + 1] = fake.old_build_id or 'devhost-initial'
    argv[#argv + 1] = '--reboot-exit-code'; argv[#argv + 1] = tostring(opts.reboot_exit_code or 42)
    argv.cwd = cwd
    argv.stdin = 'null'
    argv.stdout = 'pipe'
    argv.stderr = 'inherit'
    argv.shutdown_grace = 1.0
    argv.env = { GOMAXPROCS = tostring(opts.gomaxprocs or 1) }
    return argv, nil
end

local function start_go_mcu_instance(parent_scope, fake, uart_port, state_dir, opts)
    assert(uart_port and uart_port.slave_name, 'MCU PTY slave required')
    assert(state_dir and state_dir ~= '', 'Go MCU state dir required')
    fake.expect_mcu_fabric_event = false
    fake.mcu_fabric_session_seen = false
    fake.mcu_fabric_session = nil
    local scope = assert(parent_scope:child())
    mkdir_p(state_dir)

    local spec, spec_err = go_devhost_command_spec(uart_port.slave_name, state_dir, fake, opts)
    assert_not_nil(spec, spec_err)
    local cmd = exec.command(spec)
    local stdout, sout_err = cmd:stdout_stream()
    assert_not_nil(stdout, sout_err or 'Go MCU child stdout pipe unavailable')

    local ready_ch = channel.new(1)

    assert_true(scope:spawn(function ()
        while true do
            local line, rerr = fibers.perform(stdout:read_line_op())
            if line == nil then
                if fake.child_ready ~= true then
                    ready_ch:put({ ok = false, err = rerr or 'go mcu child stdout closed before ready' })
                end
                return
            end
            local ev, derr = cjson.decode(line)
            if not ev then
                log('Go MCU child sent invalid JSON: ' .. tostring(derr) .. ' line=' .. tostring(line))
            else
                update_fake_from_mcu_child(fake, ev)
                if ev.event == 'ready' then
                    ready_ch:put({ ok = true })
                end
            end
        end
    end))

    assert_true(scope:spawn(function ()
        local status, code, signal, err = fibers.perform(cmd:run_op())
        fake.child_exit = { status = status, code = code, signal = signal, err = err }
        if status == 'exited' and code == (opts and opts.reboot_exit_code or 42) then
            fake.reboot_exit_seen = true
            log(('Go MCU child exited for simulated reboot: code=%s'):format(tostring(code)))
        elseif status ~= 'signalled' and not (status == 'exited' and code == 0) then
            log(('Go MCU child exited: status=%s code=%s signal=%s err=%s'):format(
                tostring(status), tostring(code), tostring(signal), tostring(err)
            ))
        end
    end))

    local ready = wait_channel_get(ready_ch, 20.0, 'Go MCU child ready')
    if not ready.ok then error(ready.err or 'Go MCU child failed to start', 0) end

    return { scope = scope, command = cmd, state_dir = state_dir }
end

local function stop_instance(inst, reason)
    if inst and inst.scope then
        inst.scope:cancel(reason or 'test reboot')
        fibers.perform(inst.scope:join_op())
    end
end

local function parse_curl_output(out)
    out = tostring(out or '')
    local status = out:match('\n__HTTP_STATUS__:(%d+)%s*$')
    local body = out:gsub('\n__HTTP_STATUS__:%d+%s*$', '')
    return status, body
end

local function run_curl(args)
    local cmd = exec.command('curl', unpack(args))
    local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
    if not (st == 'exited' and code == 0) then
        error(('curl failed: status=%s code=%s signal=%s err=%s output=%s'):format(
            tostring(st), tostring(code), tostring(sig), tostring(err), tostring(out)
        ), 0)
    end
    return parse_curl_output(out)
end

local function append_headers(args, headers)
    for k, v in pairs(headers or {}) do
        args[#args + 1] = '--header'
        args[#args + 1] = tostring(k) .. ': ' .. tostring(v)
    end
end

local function run_http_upload(_scope, port, body, headers)
    local path = ('/tmp/devicecode-mcu-http-uart-upload-%d-%d.bin'):format(os.time(), math.random(100000, 999999))
    write_file(path, body)
    local args = {
        '--silent', '--show-error',
        '--request', 'POST',
        '--header', 'content-type: application/octet-stream',
        '--data-binary', '@' .. path,
        '--write-out', '\n__HTTP_STATUS__:%{http_code}\n',
    }
    append_headers(args, headers)
    args[#args + 1] = ('http://127.0.0.1:%d/api/update/upload'):format(port)
    local status, resp_body = run_curl(args)
    os.remove(path)
    return status, resp_body
end

local function run_http_json(_scope, port, path, payload, headers)
    local args = {
        '--silent', '--show-error',
        '--request', 'POST',
        '--header', 'content-type: application/json',
        '--data', assert(cjson.encode(payload or {})),
        '--write-out', '\n__HTTP_STATUS__:%{http_code}\n',
    }
    append_headers(args, headers)
    args[#args + 1] = ('http://127.0.0.1:%d%s'):format(port, path)
    local status, resp_body = run_curl(args)
    return status, resp_body, resp_body and cjson.decode(resp_body) or nil
end


function T.ui_http_mcu_update_short_stage_timeout_fails_via_outer_choice()
    runfibers.run(function (root_scope)
        local roots = temp_roots()
        local blob = make_realistic_mcu_blob('mcu-image-new')
        local port = 30000 + math.random(0, 20000)
        local fake = { old_image_id = 'mcu-image-old' }
        local uart = { cm5 = pty.open(root_scope), mcu = pty.open(root_scope) }

        log('short-timeout: booting CM5 instance')
        local cm5 = start_cm5_instance(root_scope, roots, port, uart.cm5, {
            stage_timeout_s = SHORT_STAGE_TIMEOUT_S,
            stage_action_timeout_s = REALISTIC_TRANSFER_TIMEOUT_S,
        })
        log('short-timeout: booting fake MCU instance')
        local mcu = start_mcu_instance(root_scope, fake, uart.mcu)
        log('short-timeout: starting Fabric pair over PTY UART middleware')
        local pair = start_fabric_pair(root_scope, cm5.bus, fake, uart)
        log('short-timeout: starting CM5 Device/Update/UI services')
        cm5.start_services_after_fabric()

        wait_component_software(cm5.conn, 'mcu-image-old', 'mcu-boot-1')

        log(('short-timeout: sending unauthenticated upload through curl with %.1fs update stage deadline'):format(SHORT_STAGE_TIMEOUT_S))
        local status, body = run_http_upload(root_scope, port, blob, nil)
        assert_eq(status, '200', 'upload HTTP status ' .. tostring(status) .. ': ' .. tostring(body))

        log('short-timeout: waiting for job to fail due to the outer stage deadline')
        local failed = wait_job_chatty(cm5.conn, 'job-mcu-http-uart', 'failed', 20.0, function ()
            return (('mcu_received=%d chunks=%d uart_bytes=%d uart_fragments=%d uart_pauses=%d uart_bad_json=%d; %s'):format(
                fake.receive_bytes or 0,
                fake.receive_chunks or 0,
                pair.uart_stats and pair.uart_stats.bytes or 0,
                pair.uart_stats and pair.uart_stats.fragments or 0,
                pair.uart_stats and pair.uart_stats.pauses or 0,
                pair.uart_stats and pair.uart_stats.malformed_lines or 0,
                fabric_progress_fragment(pair.cm5_conn)
            ))
        end)
        assert_contains(failed.error, 'stage_op_timeout', 'job should fail from the active stage deadline')
        assert_true((fake.receive_bytes or 0) < #blob, 'short timeout should not stage the full artifact')
        assert_true(fake.staged == nil, 'short timeout must not commit a staged artifact')
        assert_true(fake.commit_seen ~= true, 'short timeout must not reach the MCU commit RPC')
        fibers.perform(sleep.sleep_op(0.25))
        log(('short-timeout: cancellation observed abort_reason=%s abort_count=%d received=%d chunks=%d'):format(
            tostring(fake.abort_reason), fake.abort_count or 0, fake.receive_bytes or 0, fake.receive_chunks or 0
        ))

        log('short-timeout: cleanup')
        stop_fabric_pair(pair, 'short timeout complete')
        stop_instance(cm5, 'short timeout complete')
        stop_instance(mcu, 'short timeout complete')
        rm_rf(roots.base)
    end, { timeout = 60.0 })
end

function T.ui_http_mcu_update_survives_fake_reboot_and_reconciles()
    runfibers.run(function (root_scope)
        local roots = temp_roots()
        local blob = make_realistic_mcu_blob('mcu-image-new')
        local port = 30000 + math.random(0, 20000)
        local fake = { old_image_id = 'mcu-image-old' }

        local uart = { cm5 = pty.open(root_scope), mcu = pty.open(root_scope) }

        log('booting initial CM5 instance')
        local cm5 = start_cm5_instance(root_scope, roots, port, uart.cm5)
        log('booting initial fake MCU instance')
        local mcu = start_mcu_instance(root_scope, fake, uart.mcu)
        log('starting initial Fabric pair over PTY UART middleware')
        local pair = start_fabric_pair(root_scope, cm5.bus, fake, uart)
        log('starting CM5 Device/Update/UI services')
        cm5.start_services_after_fabric()

        log('waiting for initial canonical MCU software state')
        wait_component_software(cm5.conn, 'mcu-image-old', 'mcu-boot-1')

        log(('sending real HTTP upload through curl (%d byte artifact)'):format(#blob))
        local stage_started = fibers.now()
        local status, body = run_http_upload(root_scope, port, blob, nil)
        assert_eq(status, '200', 'upload HTTP status ' .. tostring(status) .. ': ' .. tostring(body))
        local decoded = assert(cjson.decode(body), body)
        assert_eq(decoded.status, 'ok')
        assert_eq(decoded.job_id, 'job-mcu-http-uart')
        assert_eq(decoded.job, nil)

        log('waiting for job awaiting_commit')
        wait_job_chatty(cm5.conn, 'job-mcu-http-uart', 'awaiting_commit', REALISTIC_TRANSFER_TIMEOUT_S, function ()
            return (('mcu_received=%d chunks=%d uart_bytes=%d uart_fragments=%d uart_pauses=%d uart_bad_json=%d; %s'):format(
                fake.receive_bytes or 0,
                fake.receive_chunks or 0,
                pair.uart_stats and pair.uart_stats.bytes or 0,
                pair.uart_stats and pair.uart_stats.fragments or 0,
                pair.uart_stats and pair.uart_stats.pauses or 0,
                pair.uart_stats and pair.uart_stats.malformed_lines or 0,
                fabric_progress_fragment(pair.cm5_conn)
            ))
        end)
        local expected_payload_digest = xxhash32.digest_hex(blob)
        assert_true(probe.wait_until(function ()
            return fake.staged
                and fake.staged.size == #blob
                and fake.staged.payload_digest == expected_payload_digest
        end, { timeout = 10.0 }), 'fake MCU should stage transferred artifact with matching digest')
        local stage_elapsed = fibers.now() - stage_started
        local uart_bytes = pair.uart_stats and pair.uart_stats.bytes or 0
        local uart_fragments = pair.uart_stats and pair.uart_stats.fragments or 0
        local uart_pauses = pair.uart_stats and pair.uart_stats.pauses or 0
        local uart_malformed_lines = pair.uart_stats and pair.uart_stats.malformed_lines or 0
        log(('artifact staged in %.1fs; middleware relayed %d bytes in %d fragments with %d long pauses and %d malformed JSONL lines'):format(
            stage_elapsed, uart_bytes, uart_fragments, uart_pauses, uart_malformed_lines
        ))
        assert_true(uart_bytes >= #blob, 'UART middleware should relay at least the artifact payload size')
        assert_true(uart_malformed_lines >= 1, 'UART middleware should inject at least one standalone malformed JSONL line')
        assert_true(
            uart_fragments >= math.floor(#blob / UART_MAX_FRAGMENT_BYTES),
            'UART middleware should fragment the byte stream heavily'
        )
        if #blob >= (2 * UART_LONG_PAUSE_EVERY_BYTES) then
            assert_true(uart_pauses >= 2, 'large UART test should inject at least two long scheduling pauses')
        end
        assert_true(
            stage_elapsed >= ((#blob / UART_BYTES_PER_SEC) * 0.75),
            'artifact should take UART-paced time to stage'
        )
        log_fabric_status(cm5.conn, 'CM5 fabric post-stage status')

        log('committing job through curl HTTP update commit route')
        local commit_status, commit_body, commit_decoded = run_http_json(
            root_scope,
            port,
            '/api/update/commit',
            { job_id = 'job-mcu-http-uart' },
            nil
        )
        assert_eq(commit_status, '200', commit_body)
        assert_not_nil(commit_decoded and commit_decoded.value, commit_body)
        assert_eq(commit_decoded.value.ok, true)
        log('waiting for job awaiting_return')
        wait_job(cm5.conn, 'job-mcu-http-uart', 'awaiting_return', 6.0)
        assert_true(probe.wait_until(function () return fake.commit_seen == true end, { timeout = 2.0 }), 'fake MCU should see commit')
        assert_eq(fake.committed_image_id, 'mcu-image-new')

        log('fake reboot: stopping Fabric pair')
        stop_fabric_pair(pair, 'fake fabric link reboot')
        log('fake reboot: stopping CM5 instance')
        stop_instance(cm5, 'fake cm5 reboot')
        log('fake reboot: stopping MCU instance')
        stop_instance(mcu, 'fake mcu reboot')

        local uart_b = { cm5 = pty.open(root_scope), mcu = pty.open(root_scope) }
        log('reboot: starting fresh CM5 instance')
        local cm5b = start_cm5_instance(root_scope, roots, nil, uart_b.cm5)
        log('reboot: starting fresh MCU instance')
        local mcub = start_mcu_instance(root_scope, fake, uart_b.mcu)
        log('reboot: starting fresh Fabric pair over PTY UART middleware')
        local pair_b = start_fabric_pair(root_scope, cm5b.bus, fake, uart_b)
        log_fabric_status(cm5b.conn, 'CM5 fabric reboot-established status')
        log('reboot: starting fresh CM5 Device/Update services')
        cm5b.start_services_after_fabric()

        log('reboot: waiting for post-boot canonical MCU software state')
        wait_component_software(cm5b.conn, 'mcu-image-new', 'mcu-boot-2')
        log('reboot: waiting for job succeeded')
        local final_job = wait_job(cm5b.conn, 'job-mcu-http-uart', 'succeeded', 8.0)
        assert_eq(final_job.component, 'mcu')
        assert_eq(final_job.job_id, 'job-mcu-http-uart')
        assert_not_nil(final_job.commit_attempt, 'job should carry commit attempt details')
        if final_job.commit_attempt and final_job.commit_attempt.pre_commit then
            assert_eq(final_job.commit_attempt.pre_commit.pre_commit_boot_id, 'mcu-boot-1')
        end

        log('cleanup: stopping second Fabric pair')
        stop_fabric_pair(pair_b, 'test complete')
        log('cleanup: stopping second CM5 instance')
        stop_instance(cm5b, 'test complete')
        log('cleanup: stopping second MCU instance')
        stop_instance(mcub, 'test complete')
        log('cleanup: removing temporary roots')
        rm_rf(roots.base)
    end, { timeout = REALISTIC_TEST_TIMEOUT_S })
end


local function run_go_devhost_pty_cycle(opts)
    opts = opts or {}
    if not go_devhost_configured() then
        log('skipping Go devhost PTY rig: set MCU_DEVHOST_PTY_BIN, DEVICECODE_GO_ROOT, or leave DEVICECODE_GO_DOWNLOAD enabled')
        return { skipped = true, reason = 'go_devhost_not_configured' }
    end
    local result
    runfibers.run(function (root_scope)
        local provider, skip_reason = resolve_go_devhost_provider()
        if provider == nil then
            log('skipping Go devhost PTY rig: ' .. tostring(skip_reason))
            result = { skipped = true, reason = skip_reason }
            return
        end
        local roots = temp_roots()
        local state_dir = roots.base .. '/go-mcu-state'
        local blob = make_realistic_mcu_blob(opts.image_id or 'mcu-image-go-new', opts.blob_bytes)
        local port = 30000 + math.random(0, 20000)
        local fake = { old_image_id = opts.old_image_id or 'mcu-image-go-old', old_version = opts.old_version or '10.0' }
        local uart = { cm5 = pty.open(root_scope), mcu = pty.open(root_scope) }
        local pair, pair_b

        log(('go-pty[%s]: booting initial CM5 instance'):format(opts.label or 'case'))
        local cm5 = start_cm5_instance(root_scope, roots, port, uart.cm5)
        log(('go-pty[%s]: booting Go MCU devhost instance'):format(opts.label or 'case'))
        local mcu = start_go_mcu_instance(root_scope, fake, uart.mcu, state_dir, { provider = provider })
        log(('go-pty[%s]: starting Fabric link over PTY UART middleware'):format(opts.label or 'case'))
        pair = start_fabric_pair(root_scope, cm5.bus, fake, uart, { uart = opts.uart })
        log(('go-pty[%s]: starting CM5 Device/Update/UI services'):format(opts.label or 'case'))
        cm5.start_services_after_fabric()

        wait_component_software(cm5.conn, fake.old_image_id, nil)

        log(('go-pty[%s]: sending HTTP upload through CM5 UI (%d byte artifact)'):format(opts.label or 'case', #blob))
        local status, body = run_http_upload(root_scope, port, blob, nil)
        assert_eq(status, '200', 'upload HTTP status ' .. tostring(status) .. ': ' .. tostring(body))
        local decoded = assert(cjson.decode(body), body)
        assert_eq(decoded.status, 'ok')
        assert_eq(decoded.job_id, 'job-mcu-http-uart')
        assert_eq(decoded.job, nil)

        log(('go-pty[%s]: waiting for Go MCU-backed job awaiting_commit'):format(opts.label or 'case'))
        wait_job_chatty(cm5.conn, 'job-mcu-http-uart', 'awaiting_commit', opts.stage_timeout_s or REALISTIC_TRANSFER_TIMEOUT_S, function ()
            return (('uart_bytes=%d uart_fragments=%d uart_pauses=%d uart_bad_json=%d uart_drop_bytes=%d uart_drop_nl=%d fault_pauses=%d; %s'):format(
                pair.uart_stats and pair.uart_stats.bytes or 0,
                pair.uart_stats and pair.uart_stats.fragments or 0,
                pair.uart_stats and pair.uart_stats.pauses or 0,
                pair.uart_stats and pair.uart_stats.malformed_lines or 0,
                pair.uart_stats and pair.uart_stats.dropped_bytes or 0,
                pair.uart_stats and pair.uart_stats.dropped_newlines or 0,
                pair.uart_stats and pair.uart_stats.fault_pauses or 0,
                fabric_progress_fragment(pair.cm5_conn)
            ))
        end)

        log(('go-pty[%s]: committing job through public HTTP update commit route'):format(opts.label or 'case'))
        local commit_status, commit_body, commit_decoded = run_http_json(
            root_scope,
            port,
            '/api/update/commit',
            { job_id = 'job-mcu-http-uart' },
            nil
        )
        assert_eq(commit_status, '200', commit_body)
        assert_not_nil(commit_decoded and commit_decoded.value, commit_body)
        assert_eq(commit_decoded.value.ok, true)
        wait_job(cm5.conn, 'job-mcu-http-uart', 'awaiting_return', 8.0)
        assert_true(probe.wait_until(function () return fake.rebooting_seen == true end, { timeout = 4.0 }), 'Go MCU child should emit rebooting event')
        assert_true(probe.wait_until(function () return fake.reboot_exit_seen == true end, { timeout = 4.0 }), 'Go MCU child should exit with simulated reboot code')

        stop_fabric_pair(pair, 'go devhost fabric link reboot')
        stop_instance(cm5, 'go devhost cm5 reboot')
        stop_instance(mcu, 'go devhost mcu reboot')

        local uart_b = { cm5 = pty.open(root_scope), mcu = pty.open(root_scope) }
        local cm5b = start_cm5_instance(root_scope, roots, nil, uart_b.cm5)
        local mcub = start_go_mcu_instance(root_scope, fake, uart_b.mcu, state_dir, { provider = provider })
        pair_b = start_fabric_pair(root_scope, cm5b.bus, fake, uart_b, { uart = opts.reboot_uart })
        log_fabric_status(cm5b.conn, 'go-pty CM5 fabric reboot-established status')
        cm5b.start_services_after_fabric()

        wait_component_software(cm5b.conn, opts.image_id or 'mcu-image-go-new', nil)
        local final_job = wait_job(cm5b.conn, 'job-mcu-http-uart', 'succeeded', 10.0)
        assert_eq(final_job.component, 'mcu')
        assert_eq(final_job.job_id, 'job-mcu-http-uart')
        assert_eq(final_job.expected_image_id, opts.image_id or 'mcu-image-go-new')

        result = {
            ok = true,
            final_job = final_job,
            first_uart_stats = pair and pair.uart_stats or nil,
            second_uart_stats = pair_b and pair_b.uart_stats or nil,
        }

        stop_fabric_pair(pair_b, 'go devhost test complete')
        stop_instance(cm5b, 'go devhost test complete')
        stop_instance(mcub, 'go devhost test complete')
        rm_rf(roots.base)
    end, { timeout = opts.timeout_s or REALISTIC_TEST_TIMEOUT_S })
    return result
end

function T.ui_http_mcu_update_go_devhost_pty_reboots_and_reconciles()
    run_go_devhost_pty_cycle({ label = 'baseline' })
end


T.__helpers = {
    log = log,
    run_go_devhost_pty_cycle = run_go_devhost_pty_cycle,
    go_devhost_configured = go_devhost_configured,
}

return T
