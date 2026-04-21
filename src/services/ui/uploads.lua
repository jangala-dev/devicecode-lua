local pulse = require 'fibers.pulse'
local cap_sdk = require 'services.hal.sdk.cap'
local errors = require 'services.ui.errors'
local uuid = require 'uuid'

local M = {}
local Uploads = {}
Uploads.__index = Uploads

local function update_create(user_conn, payload, timeout)
    return user_conn:call({ 'cmd', 'update', 'job', 'create' }, payload, { timeout = timeout or 10.0 })
end

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
        _changed = pulse.new(0),
    }, Uploads)
end

function Uploads:_set_session(upload_id, patch)
    local rec = self._sessions[upload_id] or { upload_id = upload_id }
    for k, v in pairs(patch or {}) do rec[k] = v end
    self._sessions[upload_id] = rec
    self._changed:signal()
    return rec
end

function Uploads:_clear_session(upload_id)
    self._sessions[upload_id] = nil
    self._changed:signal()
end

function Uploads:_artifact_cap(user_conn)
    return cap_sdk.new_cap_ref(user_conn, 'artifact_store', 'main')
end

function Uploads:_receive_artifact(artifact_cap, upload_id, stream, meta)
    local create_opts = assert(cap_sdk.args.new.ArtifactStoreCreateSinkOpts({
        kind = 'update_upload',
        component = meta.component,
        name = meta.name,
        version = meta.version,
        build = meta.build,
        checksum = meta.checksum,
        upload_id = upload_id,
    }, 'transient_only'))
    local reply, aerr = artifact_cap:call_control('create_sink', create_opts)
    if not reply then return nil, errors.from(aerr, 502) end
    if reply.ok ~= true then return nil, errors.from(reply.reason, 502) end
    local sink = reply.reason

    local offset = 0
    self:_set_session(upload_id, {
        state = 'receiving',
        sent = 0,
        total = meta.content_length,
        started_at = os.time(),
        updated_at = os.time(),
    })

    while true do
        local chunk, rerr = stream:get_body_chars(64 * 1024)
        if chunk == nil then
            pcall(function() sink:abort() end)
            self:_set_session(upload_id, { state = 'failed', error = tostring(rerr or 'body_read_failed'), sent = offset, updated_at = os.time() })
            return nil, errors.bad_request('body_read_failed: ' .. tostring(rerr or 'body_read_failed'))
        end
        if chunk == '' then break end
        local ok, werr = sink:write_chunk(offset, chunk)
        if not ok then
            pcall(function() sink:abort() end)
            self:_set_session(upload_id, { state = 'failed', error = tostring(werr or 'sink_write_failed'), sent = offset, updated_at = os.time() })
            return nil, errors.from(werr or 'sink_write_failed', 502)
        end
        offset = offset + #chunk
        self:_set_session(upload_id, { state = 'receiving', sent = offset, total = meta.content_length, updated_at = os.time() })
    end

    self:_set_session(upload_id, { state = 'committing', sent = offset, total = meta.content_length, updated_at = os.time() })
    local artefact, commit_err = sink:commit()
    if not artefact then
        self:_set_session(upload_id, { state = 'failed', error = tostring(commit_err or 'sink_commit_failed'), sent = offset, updated_at = os.time() })
        return nil, errors.from(commit_err or 'sink_commit_failed', 502)
    end
    return artefact, nil
end

function Uploads:_create_update_job(user_conn, artefact, meta)
    local created, uerr = update_create(user_conn, {
        component = meta.component,
        artifact = { kind = 'ref', ref = artefact:ref() },
        expected_version = meta.version,
        metadata = {
            name = meta.name,
            build = meta.build,
            checksum = meta.checksum,
            uploaded = true,
        },
    }, 10.0)
    if created == nil then return nil, uerr or errors.upstream('update_create failed') end
    return created, nil
end

function Uploads:_start_update_job(user_conn, job_id)
    local started, serr = update_do(user_conn, { op = 'start', job_id = job_id }, 10.0)
    if started == nil then return nil, serr or errors.upstream('update_start failed') end
    return started, nil
end

function Uploads:upload_update(session_id, stream, req_headers)
    local rec, err = self._require_session(session_id)
    if not rec then return nil, err end

    local upload_id = tostring(uuid.new())
    local meta = {
        component = 'mcu',
        content_length = tonumber(req_headers:get('content-length')),
        name = req_headers:get('x-artifact-name'),
        version = req_headers:get('x-artifact-version'),
        build = req_headers:get('x-artifact-build'),
        checksum = req_headers:get('x-artifact-checksum'),
    }

    local out, cerr = self._with_user_conn(rec.principal, { ui = { op = 'update_upload', component = meta.component } }, function(user_conn)
        local artifact_cap = self:_artifact_cap(user_conn)
        local artefact, rerr = self:_receive_artifact(artifact_cap, upload_id, stream, meta)
        if not artefact then return nil, rerr end

        local created, uerr = self:_create_update_job(user_conn, artefact, meta)
        if created == nil then
            local delete_opts = assert(cap_sdk.args.new.ArtifactStoreDeleteOpts(artefact:ref()))
            pcall(function() artifact_cap:call_control('delete', delete_opts) end)
            self:_set_session(upload_id, { state = 'failed', error = tostring(uerr or 'update_create_failed'), updated_at = os.time() })
            return nil, uerr
        end

        local started, serr = self:_start_update_job(user_conn, created.job.job_id)
        if started == nil then
            local delete_opts = assert(cap_sdk.args.new.ArtifactStoreDeleteOpts(artefact:ref()))
            pcall(function() artifact_cap:call_control('delete', delete_opts) end)
            self:_set_session(upload_id, { state = 'failed', error = tostring(serr or 'update_start_failed'), updated_at = os.time() })
            return nil, serr
        end

        self:_set_session(upload_id, { state = 'complete', updated_at = os.time() })
        self:_clear_session(upload_id)
        local desc = artefact:describe()
        return { ok = true, job = started.job, artifact = { ref = artefact:ref(), size = desc.size, checksum = desc.checksum } }, nil
    end)
    if out == nil then return nil, cerr or errors.upstream('update_upload failed') end
    return out, nil
end

return M
