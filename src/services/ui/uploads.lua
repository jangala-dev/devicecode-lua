local pulse = require 'fibers.pulse'
local safe = require 'coxpcall'
local cap_sdk = require 'services.hal.sdk.cap'
local errors = require 'services.ui.errors'

local M = {}
local Uploads = {}
Uploads.__index = Uploads

local function update_do(user_conn, payload, timeout)
    return user_conn:call({ 'cmd', 'update', 'job', 'do' }, payload, { timeout = timeout or 10.0 })
end

function M.new(opts)
    opts = opts or {}
    assert(type(opts.require_session) == 'function', 'uploads: require_session is required')
    assert(type(opts.with_user_conn) == 'function', 'uploads: with_user_conn is required')
    return setmetatable({
        _require_session = opts.require_session,
        _with_user_conn = opts.with_user_conn,
        _sessions = {},
        _changed = pulse.scoped({ close_reason = 'ui uploads stopped' }),
    }, Uploads)
end

function Uploads:_set_session(job_id, patch)
    local rec = self._sessions[job_id] or { job_id = job_id }
    for k, v in pairs(patch or {}) do rec[k] = v end
    self._sessions[job_id] = rec
    self._changed:signal()
    return rec
end

function Uploads:_clear_session(job_id)
    self._sessions[job_id] = nil
    self._changed:signal()
end

function Uploads:_artifact_cap(user_conn)
    return cap_sdk.new_cap_ref(user_conn, 'artifact_store', 'main')
end

function Uploads:upload_for_job(session_id, job_id, stream, req_headers)
    local rec, err = self._require_session(session_id)
    if not rec then return nil, err end

    local content_length = tonumber(req_headers:get('content-length'))
    local name = req_headers:get('x-artifact-name')
    local version = req_headers:get('x-artifact-version')
    local build = req_headers:get('x-artifact-build')
    local checksum = req_headers:get('x-artifact-checksum')

    local out, cerr = self._with_user_conn(rec.principal, { ui = { op = 'update_upload', job_id = job_id } }, function(user_conn)
        local artifact_cap = self:_artifact_cap(user_conn)
        local create_opts = assert(cap_sdk.args.new.ArtifactStoreCreateSinkOpts({
            kind = 'update_upload',
            component = 'mcu',
            name = name,
            version = version,
            build = build,
            checksum = checksum,
            job_id = job_id,
        }, 'transient_only'))
        local reply, aerr = artifact_cap:call_control('create_sink', create_opts)
        if not reply then return nil, errors.from(aerr, 502) end
        if reply.ok ~= true then return nil, errors.from(reply.reason, 502) end
        local sink = reply.reason

        local began, berr = update_do(user_conn, { op = 'upload_begin', job_id = job_id }, 5.0)
        if began == nil then
            pcall(function() sink:abort() end)
            return nil, berr or errors.upstream('upload_begin failed')
        end

        self:_set_session(job_id, {
            state = 'receiving',
            sent = 0,
            total = content_length,
            started_at = os.time(),
            updated_at = os.time(),
        })

        local offset = 0
        while true do
            local chunk, rerr = stream:get_body_chars(64 * 1024)
            if chunk == nil then
                pcall(function() sink:abort() end)
                self:_set_session(job_id, { state = 'failed', error = tostring(rerr or 'body_read_failed'), sent = offset, updated_at = os.time() })
                update_do(user_conn, { op = 'upload_failed', job_id = job_id, error = tostring(rerr or 'body_read_failed') }, 5.0)
                return nil, errors.bad_request('body_read_failed: ' .. tostring(rerr or 'body_read_failed'))
            end
            if chunk == '' then break end
            local ok, werr = sink:write_chunk(offset, chunk)
            if not ok then
                pcall(function() sink:abort() end)
                self:_set_session(job_id, { state = 'failed', error = tostring(werr or 'sink_write_failed'), sent = offset, updated_at = os.time() })
                update_do(user_conn, { op = 'upload_failed', job_id = job_id, error = tostring(werr or 'sink_write_failed') }, 5.0)
                return nil, errors.from(werr or 'sink_write_failed', 502)
            end
            offset = offset + #chunk
            self:_set_session(job_id, { state = 'receiving', sent = offset, total = content_length, updated_at = os.time() })
        end

        self:_set_session(job_id, { state = 'committing', sent = offset, total = content_length, updated_at = os.time() })
        local artefact, commit_err = sink:commit()
        if not artefact then
            self:_set_session(job_id, { state = 'failed', error = tostring(commit_err or 'sink_commit_failed'), sent = offset, updated_at = os.time() })
            update_do(user_conn, { op = 'upload_failed', job_id = job_id, error = tostring(commit_err or 'sink_commit_failed') }, 5.0)
            return nil, errors.from(commit_err or 'sink_commit_failed', 502)
        end
        local desc = artefact:describe()
        local attached, atterr = update_do(user_conn, {
            op = 'attach_artifact',
            job_id = job_id,
            artifact_ref = artefact:ref(),
            artifact_meta = desc,
            auto_start = true,
        }, 10.0)
        if attached == nil then
            safe.pcall(function()
                local delete_opts = assert(cap_sdk.args.new.ArtifactStoreDeleteOpts(artefact:ref()))
                artifact_cap:call_control('delete', delete_opts)
            end)
            self:_set_session(job_id, { state = 'failed', error = tostring(atterr or 'attach_artifact_failed'), sent = offset, updated_at = os.time() })
            update_do(user_conn, { op = 'upload_failed', job_id = job_id, error = tostring(atterr or 'attach_artifact_failed') }, 5.0)
            return nil, atterr or errors.upstream('attach_artifact failed')
        end
        self:_set_session(job_id, { state = 'complete', sent = offset, total = content_length, updated_at = os.time() })
        self:_clear_session(job_id)
        return { ok = true, job = attached.job, artifact = { ref = artefact:ref(), size = desc.size, checksum = desc.checksum } }, nil
    end)
    if out == nil then return nil, cerr or errors.upstream('update_upload failed') end
    return out, nil
end

return M
