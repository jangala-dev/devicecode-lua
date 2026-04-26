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

function T.uploads_manager_streams_into_sink_and_creates_started_job_once()
    local calls = {}
    local sink = {
        chunks = {},
        write_chunk = function(self, offset, data)
            calls[#calls + 1] = { op = 'write_chunk', offset = offset, data = data }
            self.chunks[#self.chunks + 1] = data
            return true
        end,
        abort = function() calls[#calls + 1] = { op = 'abort' } return true end,
        commit = function(self)
            calls[#calls + 1] = { op = 'commit' }
            return {
                ref = function() return 'artifact:1' end,
                describe = function() return { size = #table.concat(self.chunks), checksum = 'sha256:abc' } end,
            }, nil
        end,
    }
    local fake_conn = {
        call = function(_, topic, payload)
            local key = table.concat(topic, '/')
            calls[#calls + 1] = { op = 'call', key = key, payload = payload }
            if key == 'cap/artifact-ingest/main/rpc/create' then
                return { ok = true, reason = sink }, nil
            elseif key == 'cap/update-manager/main/rpc/create-job' then
                return { ok = true, job = { job_id = 'job-1' } }, nil
            elseif key == 'cap/update-manager/main/rpc/start-job' then
                return { ok = true, job = { job_id = 'job-1' } }, nil
            elseif key == 'cap/artifact-ingest/main/rpc/delete' then
                return { ok = true }, nil
            end
            return nil, 'unexpected'
        end,
        call_op = function(self, topic, payload)
            local reply, err = self:call(topic, payload)
            return op.always(reply, err)
        end,
    }
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
        local create_payload = calls[#calls - 1].payload
        assert(type(create_payload) == 'table' and type(create_payload.metadata) == 'table')
        assert(create_payload.metadata.commit_policy == 'manual')
        assert(create_payload.metadata.require_explicit_commit == true)
    end)
    local ops = {}
    for i = 1, #calls do
        local name = calls[i].op == 'call' and calls[i].key or calls[i].op
        if name ~= nil then ops[#ops + 1] = name end
    end
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[#ops - 2] == 'commit')
    assert(ops[#ops - 1] == 'cap/update-manager/main/rpc/create-job')
    assert(ops[#ops] == 'cap/update-manager/main/rpc/start-job')
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
    local sink = {
        write_chunk = function(_, _offset, _data)
            calls[#calls + 1] = 'write_chunk'
            return true
        end,
        abort = function()
            calls[#calls + 1] = 'abort'
            return true
        end,
        commit = function() error('should_not_commit') end,
    }
    local fake_conn = {
        call = function(_, topic, _payload)
            local key = table.concat(topic, '/')
            if key == 'cap/artifact-ingest/main/rpc/create' then
                return { ok = true, reason = sink }, nil
            end
            error('unexpected call: ' .. key)
        end,
        call_op = function(self, topic, payload)
            local reply, err = self:call(topic, payload)
            return op.always(reply, err)
        end,
    }
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
    assert(calls[1] == 'write_chunk')
    assert(calls[#calls] == 'abort')
end

function T.uploads_manager_deletes_artifact_when_update_create_fails_after_commit()
    local calls = {}
    local sink = {
        chunks = {},
        write_chunk = function(self, offset, data)
            calls[#calls + 1] = { op = 'write_chunk', offset = offset, data = data }
            self.chunks[#self.chunks + 1] = data
            return true
        end,
        abort = function() calls[#calls + 1] = { op = 'abort' } return true end,
        commit = function(self)
            calls[#calls + 1] = { op = 'commit' }
            return {
                ref = function() return 'artifact:cleanup-create' end,
                describe = function() return { size = #table.concat(self.chunks), checksum = 'sha256:cleanup-create' } end,
            }, nil
        end,
    }
    local fake_conn = {
        call = function(_, topic, payload)
            local key = table.concat(topic, '/')
            calls[#calls + 1] = { op = 'call', key = key, payload = payload }
            if key == 'cap/artifact-ingest/main/rpc/create' then
                return { ok = true, reason = sink }, nil
            elseif key == 'cap/update-manager/main/rpc/create-job' then
                return nil, 'create_failed'
            elseif key == 'cap/artifact-ingest/main/rpc/delete' then
                return { ok = true }, nil
            end
            error('unexpected call: ' .. key)
        end,
        call_op = function(self, topic, payload)
            local reply, err = self:call(topic, payload)
            return op.always(reply, err)
        end,
    }
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
    local ops = {}
    for i = 1, #calls do
        local name = calls[i].op == 'call' and calls[i].key or calls[i].op
        ops[#ops + 1] = name
    end
    assert(ops[#ops - 2] == 'commit')
    assert(ops[#ops - 1] == 'cap/update-manager/main/rpc/create-job')
    assert(ops[#ops] == 'cap/artifact-ingest/main/rpc/delete')
end

function T.uploads_manager_deletes_artifact_when_update_start_fails_after_create()
    local calls = {}
    local sink = {
        chunks = {},
        write_chunk = function(self, offset, data)
            calls[#calls + 1] = { op = 'write_chunk', offset = offset, data = data }
            self.chunks[#self.chunks + 1] = data
            return true
        end,
        abort = function() calls[#calls + 1] = { op = 'abort' } return true end,
        commit = function(self)
            calls[#calls + 1] = { op = 'commit' }
            return {
                ref = function() return 'artifact:cleanup-start' end,
                describe = function() return { size = #table.concat(self.chunks), checksum = 'sha256:cleanup-start' } end,
            }, nil
        end,
    }
    local fake_conn = {
        call = function(_, topic, payload)
            local key = table.concat(topic, '/')
            calls[#calls + 1] = { op = 'call', key = key, payload = payload }
            if key == 'cap/artifact-ingest/main/rpc/create' then
                return { ok = true, reason = sink }, nil
            elseif key == 'cap/update-manager/main/rpc/create-job' then
                return { ok = true, job = { job_id = 'job-start-fail' } }, nil
            elseif key == 'cap/update-manager/main/rpc/start-job' then
                return nil, 'start_failed'
            elseif key == 'cap/artifact-ingest/main/rpc/delete' then
                return { ok = true }, nil
            end
            error('unexpected call: ' .. key)
        end,
        call_op = function(self, topic, payload)
            local reply, err = self:call(topic, payload)
            return op.always(reply, err)
        end,
    }
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
    local ops = {}
    for i = 1, #calls do
        local name = calls[i].op == 'call' and calls[i].key or calls[i].op
        ops[#ops + 1] = name
    end
    assert(ops[#ops - 3] == 'commit')
    assert(ops[#ops - 2] == 'cap/update-manager/main/rpc/create-job')
    assert(ops[#ops - 1] == 'cap/update-manager/main/rpc/start-job')
    assert(ops[#ops] == 'cap/artifact-ingest/main/rpc/delete')
end

function T.uploads_manager_times_out_before_artifact_create()
    local calls = {}
    local fake_conn = {
        call = function(_, topic, _payload)
            calls[#calls + 1] = table.concat(topic, '/')
            error('should_not_call_upstream')
        end,
        call_op = function(self, topic, payload)
            local reply, err = self:call(topic, payload)
            return op.always(reply, err)
        end,
    }
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
    local sink = {
        write_chunk = function(_, offset, data)
            calls[#calls + 1] = { op = 'write_chunk', offset = offset, data = data }
            return true
        end,
        abort = function()
            calls[#calls + 1] = { op = 'abort' }
            return true
        end,
        commit = function()
            error('should_not_commit')
        end,
    }
    local fake_conn = {
        call = function(_, topic, _payload)
            local key = table.concat(topic, '/')
            calls[#calls + 1] = { op = 'call', key = key }
            if key == 'cap/artifact-ingest/main/rpc/create' then
                return { ok = true, reason = sink }, nil
            end
            error('unexpected call: ' .. key)
        end,
        call_op = function(self, topic, payload)
            local reply, err = self:call(topic, payload)
            return op.always(reply, err)
        end,
    }
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
    local ops = {}
    for i = 1, #calls do
        local name = calls[i].op == 'call' and calls[i].key or calls[i].op
        ops[#ops + 1] = name
    end
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[2] == 'write_chunk')
    assert(ops[#ops] == 'abort')
end

function T.uploads_manager_times_out_before_create_job_after_successful_receive()
    local calls = {}
    local sink = {
        chunks = {},
        write_chunk = function(self, offset, data)
            calls[#calls + 1] = { op = 'write_chunk', offset = offset, data = data }
            self.chunks[#self.chunks + 1] = data
            return true
        end,
        abort = function()
            calls[#calls + 1] = { op = 'abort' }
            return true
        end,
        commit = function(self)
            calls[#calls + 1] = { op = 'commit' }
            return {
                ref = function() return 'artifact:timeout-before-create' end,
                describe = function() return { size = #table.concat(self.chunks), checksum = 'sha256:timeout-before-create' } end,
            }, nil
        end,
    }
    local fake_conn = {
        call = function(_, topic, _payload)
            local key = table.concat(topic, '/')
            calls[#calls + 1] = { op = 'call', key = key }
            if key == 'cap/artifact-ingest/main/rpc/create' then
                return { ok = true, reason = sink }, nil
            elseif key == 'cap/artifact-ingest/main/rpc/delete' then
                return { ok = true }, nil
            end
            error('unexpected call: ' .. key)
        end,
        call_op = function(self, topic, payload)
            local reply, err = self:call(topic, payload)
            return op.always(reply, err)
        end,
    }
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
    local ops = {}
    for i = 1, #calls do
        local name = calls[i].op == 'call' and calls[i].key or calls[i].op
        ops[#ops + 1] = name
    end
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[#ops - 1] == 'commit')
    assert(ops[#ops] == 'cap/artifact-ingest/main/rpc/delete')
end

function T.uploads_manager_times_out_before_start_after_create_job()
    local calls = {}
    local sink = {
        chunks = {},
        write_chunk = function(self, offset, data)
            calls[#calls + 1] = { op = 'write_chunk', offset = offset, data = data }
            self.chunks[#self.chunks + 1] = data
            return true
        end,
        abort = function()
            calls[#calls + 1] = { op = 'abort' }
            return true
        end,
        commit = function(self)
            calls[#calls + 1] = { op = 'commit' }
            return {
                ref = function() return 'artifact:timeout-before-start' end,
                describe = function() return { size = #table.concat(self.chunks), checksum = 'sha256:timeout-before-start' } end,
            }, nil
        end,
    }
    local fake_conn = {
        call = function(_, topic, _payload)
            local key = table.concat(topic, '/')
            calls[#calls + 1] = { op = 'call', key = key }
            if key == 'cap/artifact-ingest/main/rpc/create' then
                return { ok = true, reason = sink }, nil
            elseif key == 'cap/update-manager/main/rpc/create-job' then
                sleep.sleep(0.02)
                return { ok = true, job = { job_id = 'job-timeout-before-start' } }, nil
            elseif key == 'cap/artifact-ingest/main/rpc/delete' then
                return { ok = true }, nil
            elseif key == 'cap/update-manager/main/rpc/start-job' then
                error('should_not_start_job')
            end
            error('unexpected call: ' .. key)
        end,
        call_op = function(self, topic, payload)
            local reply, err = self:call(topic, payload)
            return op.always(reply, err)
        end,
    }
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
    local ops = {}
    for i = 1, #calls do
        local name = calls[i].op == 'call' and calls[i].key or calls[i].op
        ops[#ops + 1] = name
    end
    assert(ops[1] == 'cap/artifact-ingest/main/rpc/create')
    assert(ops[#ops - 2] == 'commit')
    assert(ops[#ops - 1] == 'cap/update-manager/main/rpc/create-job')
    assert(ops[#ops] == 'cap/artifact-ingest/main/rpc/delete')
end

return T
