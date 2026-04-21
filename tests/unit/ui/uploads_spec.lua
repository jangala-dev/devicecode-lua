local T = {}

local ui_fakes = require 'tests.support.ui_fakes'
local uploads_mod = require 'services.ui.uploads'

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
            if key == 'cap/artifact_store/main/rpc/create_sink' then
                return { ok = true, reason = sink }, nil
            elseif key == 'cmd/update/job/create' then
                return { ok = true, job = { job_id = 'job-1' } }, nil
            elseif key == 'cmd/update/job/do' then
                return { ok = true, job = { job_id = 'job-1' } }, nil
            elseif key == 'cap/artifact_store/main/rpc/delete' then
                return { ok = true }, nil
            end
            return nil, 'unexpected'
        end,
    }
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
            ['x-update-component'] = 'mcu',
            ['x-artifact-version'] = 'mcu-v1',
        },
    })
    local out, err = uploads:upload_update('sess-1', stream, stream:get_headers())
    assert(err == nil)
    assert(out.ok == true)
    assert(out.artifact.ref == 'artifact:1')
    local ops = {}
    for i = 1, #calls do
        local name = calls[i].op == 'call' and calls[i].key or calls[i].op
        if name ~= nil then ops[#ops + 1] = name end
    end
    assert(ops[1] == 'cap/artifact_store/main/rpc/create_sink')
    assert(ops[#ops - 2] == 'commit')
    assert(ops[#ops - 1] == 'cmd/update/job/create')
    assert(ops[#ops] == 'cmd/update/job/do')
end

return T
