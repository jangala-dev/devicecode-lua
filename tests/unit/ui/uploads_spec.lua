local T = {}

local ui_fakes = require 'tests.support.ui_fakes'
local uploads_mod = require 'services.ui.uploads'

function T.uploads_manager_streams_into_sink_and_attaches_once()
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
            elseif key == 'cmd/update/job/do' then
                if payload.op == 'attach_artifact' then
                    return { ok = true, job = { job_id = payload.job_id } }, nil
                end
                return { ok = true, job = { job_id = payload.job_id } }, nil
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
        path = '/api/update/jobs/job-1/artifact',
        body = 'abcdef',
        headers = {
            [':method'] = 'POST',
            [':path'] = '/api/update/jobs/job-1/artifact',
            ['content-length'] = '6',
            ['x-artifact-name'] = 'mcu.bin',
        },
    })
    local out, err = uploads:upload_for_job('sess-1', 'job-1', stream, stream:get_headers())
    assert(err == nil)
    assert(out.ok == true)
    assert(out.artifact.ref == 'artifact:1')
    local ops = {}
    for i = 1, #calls do
        local name = calls[i].op == 'call' and calls[i].payload.op or calls[i].op
        if name ~= nil then ops[#ops + 1] = name end
    end
    -- create sink, begin upload, write, commit sink, attach artefact
    assert(ops[2] == 'upload_begin')
    assert(ops[#ops - 1] == 'commit')
    assert(ops[#ops] == 'attach_artifact')
    for i = 1, #ops do assert(ops[i] ~= 'upload_progress') end
end

return T
