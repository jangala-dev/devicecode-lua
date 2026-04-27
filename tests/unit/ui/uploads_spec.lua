local T = {}

local ui_fakes = require 'tests.support.ui_fakes'
local runfibers = require 'tests.support.run_fibers'
local op = require 'fibers.op'
local uploads_mod = require 'services.ui.uploads'
local sleep = require 'fibers.sleep'

local function timed_http_stream(opts)
    opts = opts or {}
    local req_headers = ui_fakes.make_headers(opts.headers or {
        [':method'] = opts.method or 'POST',
        [':path'] = opts.path or '/api/update/uploads',
    })
    local stream = {
        _req_headers = req_headers,
        _steps = opts.steps or {},
        _idx = 1,
    }

    function stream:get_headers()
        return self._req_headers
    end

    function stream:get_body_chars(_n)
        local step = self._steps[self._idx]
        self._idx = self._idx + 1
        if not step then return '' end
        if step.sleep_s and step.sleep_s > 0 then
            sleep.sleep(step.sleep_s)
        end
        if step.err then
            return nil, step.err
        end
        return step.chunk
    end

    return stream
end

local function make_artifact(ref, chunks, checksum)
    return {
        ref = function() return ref end,
        describe = function()
            return { size = #table.concat(chunks or {}), checksum = checksum or 'sha256:abc' }
        end,
    }
end

local function call_key(topic)
    return table.concat(topic, '/')
end

local function make_fake_conn(calls, opts)
    opts = opts or {}
    local ingest_id = opts.ingest_id or 'ingest-1'
    local chunks = {}
    local expected_offset = 0

    local fake_conn = {}

    function fake_conn:call(topic, payload, opts3)
        local key = call_key(topic)
        calls[#calls + 1] = { op = 'call', key = key, payload = payload }

        if key == 'cap/artifact-ingest/main/rpc/create' then
            if opts.create_ingest_error then return nil, opts.create_ingest_error end
            return { ok = true, ingest_id = ingest_id }, nil
        end

        if key == 'cap/artifact-ingest/main/rpc/append' then
            if opts.append_error then return nil, opts.append_error end
            assert(payload.ingest_id == ingest_id)
            assert(payload.offset == expected_offset)
            assert(type(payload.data) == 'string')
            chunks[#chunks + 1] = payload.data
            expected_offset = expected_offset + #payload.data
            calls[#calls + 1] = { op = 'write_chunk', offset = payload.offset, data = payload.data }
            return { ok = true, ingest_id = ingest_id, offset = expected_offset }, nil
        end

        if key == 'cap/artifact-ingest/main/rpc/commit' then
            if opts.commit_error then return nil, opts.commit_error end
            assert(payload.ingest_id == ingest_id)
            calls[#calls + 1] = { op = 'commit' }
            local ref = opts.artifact_ref or 'artifact:1'
            return { ok = true, ingest_id = ingest_id, artifact = make_artifact(ref, chunks, opts.checksum) }, nil
        end

        if key == 'cap/artifact-ingest/main/rpc/abort' then
            assert(payload.ingest_id == ingest_id)
            calls[#calls + 1] = { op = 'abort' }
            return { ok = true, ingest_id = ingest_id }, nil
        end

        if key == 'cap/update-manager/main/rpc/create-job' then
            if opts.create_job_sleep_s then
                sleep.sleep(opts.create_job_sleep_s)
                if opts3 and opts3.timeout and opts.create_job_sleep_s > opts3.timeout then
                    return nil, 'timeout'
                end
            end
            if opts.create_job_error then return nil, opts.create_job_error end
            return { ok = true, job = { job_id = opts.job_id or 'job-1' } }, nil
        end

        if key == 'cap/update-manager/main/rpc/start-job' then
            if opts.start_job_sleep_s then
                sleep.sleep(opts.start_job_sleep_s)
                if opts3 and opts3.timeout and opts.start_job_sleep_s > opts3.timeout then
                    return nil, 'timeout'
                end
            end
            if opts.start_job_error then return nil, opts.start_job_error end
            if opts.start_job_should_not_call then error('should_not_start_job') end
            return { ok = true, job = { job_id = opts.job_id or 'job-1' } }, nil
        end

        return nil, 'unexpected:' .. key
    end

    function fake_conn:call_op(topic, payload)
        local reply, err = self:call(topic, payload)
        return op.always(reply, err)
    end

    return fake_conn
end

local function op_names(calls)
    local ops = {}
    for i = 1, #calls do
        local c = calls[i]
        local name = c.op == 'call' and c.key or c.op
        if name then ops[#ops + 1] = name end
    end
    return ops
end

function T.uploads_manager_streams_into_sink_and_creates_started_job_once()
    local calls = {}
    local fake_conn = make_fake_conn(calls, { artifact_ref = 'artifact:1', job_id = 'job-1' })

    runfibers.run(function()
        local uploads = uploads_mod.new({
            require_session = function(session_id)
                assert(session_id == 'sess-1')
                return { principal = ui_fakes.principal('u1') }, nil
            end,
            with_user_conn = function(_principal, _origin, fn)
                return fn(fake_conn)
            end,
        })
        local stream = ui_fakes.fake_http_stream({
            method = 'POST',
            path = '/api/update/uploads',
            body = 'abcdef',
            headers = {
                [':method'] = 'POST',
                [':path'] = '/api/update/uploads',
                ['content-length'] = '6',
                ['x-artifact-name'] = 'mcu.bin',
                ['x-artifact-version'] = 'mcu-v1',
            },
        })
        local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
        assert(err == nil)
        assert(out.ok == true)
        assert(out.artifact.ref == 'artifact:1')
        assert(type(out.update_flow) == 'table')
        assert(out.update_flow.staged == true)
        assert(out.update_flow.requires_commit == true)
        assert(out.update_flow.next_action == 'commit')

        local create_payload
        for _, c in ipairs(calls) do
            if c.key == 'cap/update-manager/main/rpc/create-job' then
                create_payload = c.payload
                break
            end
        end
        assert(type(create_payload) == 'table' and type(create_payload.metadata) == 'table')
        assert(create_payload.metadata.commit_policy == 'manual')
        assert(create_payload.metadata.require_explicit_commit == true)
    end)

    local ops = op_names(calls)
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[2] == 'cap/artifact-ingest/main/rpc/append')
    assert(ops[3] == 'write_chunk')
    assert(ops[4] == 'cap/artifact-ingest/main/rpc/commit')
    assert(ops[5] == 'commit')
    assert(ops[6] == 'cap/update-manager/main/rpc/create-job')
    assert(ops[7] == 'cap/update-manager/main/rpc/start-job')
end

function T.uploads_manager_rejects_component_not_allowed()
    local uploads = uploads_mod.new({
        require_session = function() return { principal = ui_fakes.principal('u1') }, nil end,
        with_user_conn = function(_principal, _origin, fn)
            return fn({
                call = function() error('should_not_call_upstream') end,
                call_op = function() error('should_not_call_upstream') end,
            })
        end,
        allowed_components = { cm5 = true },
    })
    local stream = ui_fakes.fake_http_stream({
        method = 'POST',
        path = '/api/update/uploads',
        body = 'abcdef',
        headers = {
            [':method'] = 'POST',
            [':path'] = '/api/update/uploads',
            ['content-length'] = '6',
            ['x-artifact-component'] = 'mcu',
        },
    })
    local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
    assert(out == nil)
    assert(type(err) == 'table')
    assert(err.code == 'bad_request')
    assert(err.http_status == 400)
end

function T.uploads_manager_rejects_too_large_body()
    local calls = {}
    local fake_conn = make_fake_conn(calls)

    runfibers.run(function()
        local uploads = uploads_mod.new({
            require_session = function() return { principal = ui_fakes.principal('u1') }, nil end,
            with_user_conn = function(_principal, _origin, fn) return fn(fake_conn) end,
            max_bytes = 3,
        })
        local stream = ui_fakes.fake_http_stream({
            method = 'POST',
            path = '/api/update/uploads',
            body = 'abcdef',
            headers = {
                [':method'] = 'POST',
                [':path'] = '/api/update/uploads',
                ['content-length'] = '6',
                ['x-artifact-component'] = 'mcu',
            },
        })
        local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
        assert(out == nil)
        assert(type(err) == 'table')
        assert(err.code == 'bad_request')
        assert(err.http_status == 400)
    end)
    local ops = op_names(calls)
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[2] == 'cap/artifact-ingest/main/rpc/append')
    assert(ops[#ops - 1] == 'cap/artifact-ingest/main/rpc/abort')
    assert(ops[#ops] == 'abort')
end

function T.uploads_manager_does_not_publicly_delete_artifact_when_update_create_fails_after_commit()
    local calls = {}
    local fake_conn = make_fake_conn(calls, { artifact_ref = 'artifact:cleanup-create', checksum = 'sha256:cleanup-create', create_job_error = 'create_failed' })
    runfibers.run(function()
        local uploads = uploads_mod.new({
            require_session = function() return { principal = ui_fakes.principal('u1') }, nil end,
            with_user_conn = function(_principal, _origin, fn) return fn(fake_conn) end,
        })
        local stream = ui_fakes.fake_http_stream({
            method = 'POST',
            path = '/api/update/uploads',
            body = 'abcdef',
            headers = {
                [':method'] = 'POST',
                [':path'] = '/api/update/uploads',
                ['content-length'] = '6',
                ['x-artifact-component'] = 'mcu',
                ['x-artifact-name'] = 'mcu.bin',
            },
        })
        local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
        assert(out == nil)
        assert(err == 'create_failed')
    end)
    local ops = op_names(calls)
    assert(ops[#ops - 2] == 'cap/artifact-ingest/main/rpc/commit')
    assert(ops[#ops - 1] == 'commit')
    assert(ops[#ops] == 'cap/update-manager/main/rpc/create-job')
end

function T.uploads_manager_does_not_publicly_delete_artifact_when_update_start_fails_after_create()
    local calls = {}
    local fake_conn = make_fake_conn(calls, { artifact_ref = 'artifact:cleanup-start', checksum = 'sha256:cleanup-start', job_id = 'job-start-fail', start_job_error = 'start_failed' })
    runfibers.run(function()
        local uploads = uploads_mod.new({
            require_session = function() return { principal = ui_fakes.principal('u1') }, nil end,
            with_user_conn = function(_principal, _origin, fn) return fn(fake_conn) end,
        })
        local stream = ui_fakes.fake_http_stream({
            method = 'POST',
            path = '/api/update/uploads',
            body = 'abcdef',
            headers = {
                [':method'] = 'POST',
                [':path'] = '/api/update/uploads',
                ['content-length'] = '6',
                ['x-artifact-component'] = 'mcu',
                ['x-artifact-name'] = 'mcu.bin',
            },
        })
        local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
        assert(out == nil)
        assert(err == 'start_failed')
    end)
    local ops = op_names(calls)
    assert(ops[#ops - 3] == 'cap/artifact-ingest/main/rpc/commit')
    assert(ops[#ops - 2] == 'commit')
    assert(ops[#ops - 1] == 'cap/update-manager/main/rpc/create-job')
    assert(ops[#ops] == 'cap/update-manager/main/rpc/start-job')
end

function T.uploads_manager_times_out_before_artifact_create()
    local calls = {}
    local fake_conn = make_fake_conn(calls)
    runfibers.run(function()
        local uploads = uploads_mod.new({
            require_session = function() return { principal = ui_fakes.principal('u1') }, nil end,
            with_user_conn = function(_principal, _origin, fn) return fn(fake_conn) end,
            upload_timeout_s = 0,
        })
        local stream = ui_fakes.fake_http_stream({
            method = 'POST',
            path = '/api/update/uploads',
            body = 'abcdef',
            headers = {
                [':method'] = 'POST',
                [':path'] = '/api/update/uploads',
                ['content-length'] = '6',
                ['x-artifact-component'] = 'mcu',
            },
        })
        local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
        assert(out == nil)
        assert(type(err) == 'table')
        assert(err.code == 'timeout')
        assert(err.http_status == 504)
    end)
    assert(#calls == 0)
end

function T.uploads_manager_aborts_sink_when_deadline_expires_during_receive()
    local calls = {}
    local fake_conn = make_fake_conn(calls)
    runfibers.run(function()
        local uploads = uploads_mod.new({
            require_session = function() return { principal = ui_fakes.principal('u1') }, nil end,
            with_user_conn = function(_principal, _origin, fn) return fn(fake_conn) end,
            upload_timeout_s = 0.01,
        })
        local stream = timed_http_stream({
            headers = {
                [':method'] = 'POST',
                [':path'] = '/api/update/uploads',
                ['x-artifact-component'] = 'mcu',
            },
            steps = {
                { chunk = 'abc', sleep_s = 0.02 },
            },
        })
        local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
        assert(out == nil)
        assert(type(err) == 'table')
        assert(err.code == 'timeout')
    end)
    local ops = op_names(calls)
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[2] == 'cap/artifact-ingest/main/rpc/append')
    assert(ops[#ops - 1] == 'cap/artifact-ingest/main/rpc/abort')
    assert(ops[#ops] == 'abort')
end

function T.uploads_manager_times_out_before_create_job_after_successful_receive()
    local calls = {}
    local fake_conn = make_fake_conn(calls, { artifact_ref = 'artifact:timeout-before-create', checksum = 'sha256:timeout-before-create' })
    runfibers.run(function()
        local uploads = uploads_mod.new({
            require_session = function() return { principal = ui_fakes.principal('u1') }, nil end,
            with_user_conn = function(_principal, _origin, fn) return fn(fake_conn) end,
            upload_timeout_s = 0.01,
        })
        local stream = timed_http_stream({
            headers = {
                [':method'] = 'POST',
                [':path'] = '/api/update/uploads',
                ['x-artifact-component'] = 'mcu',
                ['x-artifact-name'] = 'mcu.bin',
            },
            steps = {
                { chunk = 'abcdef' },
                { chunk = '', sleep_s = 0.02 },
            },
        })
        local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
        assert(out == nil)
        assert(type(err) == 'table')
        assert(err.code == 'timeout')
    end)
    local ops = op_names(calls)
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[#ops - 1] == 'cap/artifact-ingest/main/rpc/commit')
    assert(ops[#ops] == 'commit')
end

function T.uploads_manager_times_out_before_start_after_create_job()
    local calls = {}
    local fake_conn = make_fake_conn(calls, {
        artifact_ref = 'artifact:timeout-before-start',
        checksum = 'sha256:timeout-before-start',
        create_job_sleep_s = 0.02,
        job_id = 'job-timeout-before-start',
        start_job_should_not_call = true,
    })
    runfibers.run(function()
        local uploads = uploads_mod.new({
            require_session = function() return { principal = ui_fakes.principal('u1') }, nil end,
            with_user_conn = function(_principal, _origin, fn) return fn(fake_conn) end,
            upload_timeout_s = 0.01,
        })
        local stream = ui_fakes.fake_http_stream({
            method = 'POST',
            path = '/api/update/uploads',
            body = 'abcdef',
            headers = {
                [':method'] = 'POST',
                [':path'] = '/api/update/uploads',
                ['content-length'] = '6',
                ['x-artifact-component'] = 'mcu',
                ['x-artifact-name'] = 'mcu.bin',
            },
        })
        local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
        assert(out == nil)
        assert(type(err) == 'table')
        assert(err.code == 'timeout')
    end)
    local ops = op_names(calls)
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[#ops - 2] == 'cap/artifact-ingest/main/rpc/commit')
    assert(ops[#ops - 1] == 'commit')
    assert(ops[#ops] == 'cap/update-manager/main/rpc/create-job')
end

return T
