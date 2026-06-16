-- tests/integration/devhost/mcu_update_full_path_spec.lua
--
-- Realistic devhost MCU update flow:
--   browser HTTP upload -> UI -> Update -> Device -> real paired Fabric -> fake MCU,
--   then fake reboot of both Lua instances and Update reconciliation from the
--   control-store-backed durable job plus post-boot Device canonical state.

local busmod   = require 'bus'
local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'

local cjson_ok, cjson = pcall(require, 'cjson.safe')
if not cjson_ok then cjson = require 'cjson' end
local posix_ok, stdlib = pcall(require, 'posix.stdlib')

local http_request = require 'http.request'

local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'

local bus_cleanup = require 'devicecode.support.bus_cleanup'

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
local http_topics     = require 'services.http.topics'

local T = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function log(msg)
    io.stderr:write('[mcu-full-path] ' .. tostring(msg) .. '\n')
end

local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
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

local function temp_roots()
    local base = ('/tmp/devicecode-mcu-full-%d-%d'):format(os.time(), math.random(100000, 999999))
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

local function wait_job(conn, job_id, state, timeout)
    return wait_retained_payload_where(conn, update_topics.workflow_update_job(job_id), 'update job ' .. tostring(job_id) .. ' ' .. tostring(state), function (p)
        if p and p.state == state then return p end
        return nil
    end, { timeout = timeout or 4.0 })
end

local function wait_component_software(conn, image_id, boot_id)
    return wait_retained_payload_where(conn, device_topics.component_software('mcu'), 'mcu software canonical state', function (p)
        if p and (image_id == nil or p.image_id == image_id) and (boot_id == nil or p.boot_id == boot_id) then return p end
        return nil
    end, { timeout = 4.0 })
end

local function start_public_fabric(scope, conn, cfg, transport, opts)
    opts = opts or {}
    local link_overrides = opts.link_overrides or {
        ['link-a'] = {
            open_transport_op = function () return wrap_session_op(transport.session) end,
            transfer = opts.transfer,
        },
    }
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
    }, { chunk_size = 2048, timeout_s = 4.0 })
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
    }, { chunk_size = 2048, timeout_s = 4.0 })
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
        assert_eq(req.target, 'updater/main')
        local chunks = {}
        local sink = {}
        function sink:append_op(chunk)
            chunks[#chunks + 1] = chunk
            return fibers.always(true, nil)
        end
        function sink:commit_op(req2)
            local bytes = table.concat(chunks)
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
            timeout_s = opts.timeout or params.timeout or 4.0,
        }, { timeout = opts.timeout or params.timeout or 4.0 }):wrap(function (reply, err)
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

local function update_config()
    return {
        schema = 'devicecode.update/1',
        components = {
            { component = 'mcu' },
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
    conn:retain({ 'cfg', 'hal' }, { data = {
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
    } })
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

local function start_device(scope, bus, fabric_client)
    local conn = bus:connect({ origin_base = { service = 'device' } })
    assert_true(scope:spawn(function (s)
        device_service.run(s, {
            conn = conn,
            initial_config = { schema = 'devicecode.config/device/1' },
            fabric_client = fabric_client,
            watch_config = false,
        })
    end))
    wait_retained_payload_where(conn, device_topics.component_cap_status('mcu'), 'mcu component cap available', function (p)
        return p and p.available == true and p
    end, { timeout = 4.0 })
    return conn
end

local function start_update(scope, bus)
    local conn = bus:connect({ origin_base = { service = 'update' } })
    assert_true(scope:spawn(function (s)
        update_service.run(s, {
            conn = conn,
            service_id = 'update',
            watch_config = false,
            config = update_config(),
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
                ingest_id = 'ing-mcu-full-path',
                job_id = 'job-mcu-full-path',
                create_job = true,
                start_job = true,
                timeout = 8.0,
                chunk_size = 4096,
                metadata = {
                    source = 'browser',
                    format = 'dcmcu-v1',
                    expected_image_id = 'mcu-image-new',
                    image_id = 'mcu-image-new',
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

local function start_fabric_pair(parent_scope, cm5_bus, mcu_bus, fake)
    local pair_scope = assert(parent_scope:child())
    local transport_cm5 = new_line_transport()
    local transport_mcu = new_line_transport()
    connect_line_transports(transport_cm5, transport_mcu)

    local cm5_conn = cm5_bus:connect({ origin_base = { service = 'fabric-cm5' } })
    local mcu_conn = mcu_bus:connect({ origin_base = { service = 'fabric-mcu' } })

    start_public_fabric(pair_scope, cm5_conn, cm5_fabric_config(), transport_cm5, { name = 'fabric-cm5' })
    start_public_fabric(pair_scope, mcu_conn, mcu_fabric_config(), transport_mcu, {
        name = 'fabric-mcu',
        link_overrides = {
            ['link-a'] = {
                open_transport_op = function () return wrap_session_op(transport_mcu.session) end,
                transfer = {
                    chunk_size = 2048,
                    timeout_s = 4.0,
                    receive_targets = { ['updater/main'] = new_mcu_receive_target(fake) },
                },
            },
        },
    })

    wait_retained_payload_where(cm5_conn, fabric_topics.transfer_manager_status(), 'cm5 fabric transfer manager available', function (p)
        return p and p.available == true and p
    end, { timeout = 4.0 })

    return {
        scope = pair_scope,
        cm5_conn = cm5_conn,
        mcu_conn = mcu_conn,
    }
end

local function stop_fabric_pair(pair, reason)
    if not pair then return end
    if pair.scope then
        pair.scope:cancel(reason or 'fabric pair stop')
        fibers.perform(pair.scope:join_op())
    end
    bus_cleanup.disconnect(pair.cm5_conn)
    bus_cleanup.disconnect(pair.mcu_conn)
end

local function start_cm5_instance(parent_scope, roots, port)
    local scope = assert(parent_scope:child())
    local bus = busmod.new()
    local conn = bus:connect({ origin_base = { service = 'test-cm5' } })

    start_hal(scope, bus, roots)
    start_http(scope, bus)

    return {
        scope = scope,
        bus = bus,
        conn = conn,
        start_services_after_fabric = function (fabric_client)
            start_device(scope, bus, fabric_client)
            start_update(scope, bus)
            if port then start_ui(scope, bus, port, roots) end
        end,
    }
end

local function start_mcu_instance(parent_scope, fake)
    local scope = assert(parent_scope:child())
    local bus = busmod.new()
    local conn = bus:connect({ origin_base = { service = 'test-mcu' } })
    start_fake_mcu(scope, bus, fake)
    return { scope = scope, bus = bus, conn = conn }
end

local function stop_instance(inst, reason)
    if inst and inst.scope then
        inst.scope:cancel(reason or 'test reboot')
        fibers.perform(inst.scope:join_op())
    end
end

local function run_http_upload(scope, port, body)
    local driver = assert(http_driver_mod.new({ label = 'mcu-full-path-http-client' }))
    assert_true(driver:start(scope), 'HTTP upload client driver should start')
    local status, resp_body = fibers.perform(driver:run_op('mcu-full-path-upload', function ()
        local req = http_request.new_from_uri(('http://127.0.0.1:%d/api/update/upload'):format(port))
        req.headers:upsert(':method', 'POST')
        req.headers:upsert('content-type', 'application/octet-stream')
        req.headers:upsert('content-length', tostring(#body))
        req:set_body(body)
        local headers, stream = assert(req:go(8))
        local status = headers:get(':status')
        local response_body, body_err = stream:get_body_as_string(8)
        if response_body == nil then
            response_body = ('<response body read failed: %s>'):format(tostring(body_err))
        end
        return status, response_body
    end))
    driver:terminate('upload complete')
    return status, resp_body
end


local function run_http_json(scope, port, path, payload, headers)
    headers = headers or {}
    local driver = assert(http_driver_mod.new({ label = 'mcu-full-path-http-json-client' }))
    assert_true(driver:start(scope), 'HTTP JSON client driver should start')
    local status, resp_body = fibers.perform(driver:run_op('mcu-full-path-json', function ()
        local req = http_request.new_from_uri(('http://127.0.0.1:%d%s'):format(port, path))
        req.headers:upsert(':method', 'POST')
        req.headers:upsert('content-type', 'application/json')
        for k, v in pairs(headers) do
            req.headers:upsert(k, tostring(v))
        end
        req:set_body(assert(cjson.encode(payload or {})))
        local resp_headers, stream = assert(req:go(8))
        local status = resp_headers:get(':status')
        local response_body, body_err = stream:get_body_as_string(8)
        if response_body == nil then
            response_body = ('<response body read failed: %s>'):format(tostring(body_err))
        end
        return status, response_body
    end))
    driver:terminate('json complete')
    return status, resp_body, resp_body and cjson.decode(resp_body) or nil
end

function T.ui_http_mcu_update_survives_fake_reboot_and_reconciles()
    runfibers.run(function (root_scope)
        local roots = temp_roots()
        local blob = ('DCMCU-v1 manifest:%s\n'):format('mcu-image-new') .. string.rep('payload-', 64)
        local port = 30000 + math.random(0, 20000)
        local fake = { old_image_id = 'mcu-image-old' }

        log('booting initial CM5 instance')
        local cm5 = start_cm5_instance(root_scope, roots, port)
        log('booting initial fake MCU instance')
        local mcu = start_mcu_instance(root_scope, fake)
        log('starting initial Fabric pair')
        local pair = start_fabric_pair(root_scope, cm5.bus, mcu.bus, fake)
        log('starting CM5 Device/Update/UI services')
        cm5.start_services_after_fabric(new_fabric_client(cm5.bus:connect({ origin_base = { service = 'device-fabric-client' } })))

        log('waiting for initial canonical MCU software state')
        wait_component_software(cm5.conn, 'mcu-image-old', 'mcu-boot-1')

        log('sending real HTTP upload')
        local status, body = run_http_upload(root_scope, port, blob)
        assert_eq(status, '200', 'upload HTTP status ' .. tostring(status) .. ': ' .. tostring(body))
        local decoded = assert(cjson.decode(body), body)
        assert_eq(decoded.status, 'ok')
        assert_eq(decoded.job_id, 'job-mcu-full-path')
        assert_eq(decoded.job, nil)

        log('waiting for job awaiting_commit')
        wait_job(cm5.conn, 'job-mcu-full-path', 'awaiting_commit', 8.0)
        assert_true(probe.wait_until(function ()
            return fake.staged and fake.staged.bytes == blob
        end, { timeout = 4.0 }), 'fake MCU should stage transferred artifact')

        log('committing job through real HTTP update commit route')
        local commit_status, commit_body, commit_decoded = run_http_json(
            root_scope,
            port,
            '/api/update/commit',
            { job_id = 'job-mcu-full-path' },
            nil
        )
        assert_eq(commit_status, '200', commit_body)
        assert_not_nil(commit_decoded and commit_decoded.value, commit_body)
        assert_eq(commit_decoded.value.ok, true)
        log('waiting for job awaiting_return')
        wait_job(cm5.conn, 'job-mcu-full-path', 'awaiting_return', 6.0)
        assert_true(probe.wait_until(function () return fake.commit_seen == true end, { timeout = 2.0 }), 'fake MCU should see commit')
        assert_eq(fake.committed_image_id, 'mcu-image-new')

        log('fake reboot: stopping Fabric pair')
        stop_fabric_pair(pair, 'fake fabric link reboot')
        log('fake reboot: stopping CM5 instance')
        stop_instance(cm5, 'fake cm5 reboot')
        log('fake reboot: stopping MCU instance')
        stop_instance(mcu, 'fake mcu reboot')

        log('reboot: starting fresh CM5 instance')
        local cm5b = start_cm5_instance(root_scope, roots, nil)
        log('reboot: starting fresh MCU instance')
        local mcub = start_mcu_instance(root_scope, fake)
        log('reboot: starting fresh Fabric pair')
        local pair_b = start_fabric_pair(root_scope, cm5b.bus, mcub.bus, fake)
        log('reboot: starting fresh CM5 Device/Update services')
        cm5b.start_services_after_fabric(new_fabric_client(cm5b.bus:connect({ origin_base = { service = 'device-fabric-client-boot2' } })))

        log('reboot: waiting for post-boot canonical MCU software state')
        wait_component_software(cm5b.conn, 'mcu-image-new', 'mcu-boot-2')
        log('reboot: waiting for job succeeded')
        local final_job = wait_job(cm5b.conn, 'job-mcu-full-path', 'succeeded', 8.0)
        assert_eq(final_job.component, 'mcu')
        assert_eq(final_job.job_id, 'job-mcu-full-path')
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
    end, { timeout = 30.0 })
end

return T
