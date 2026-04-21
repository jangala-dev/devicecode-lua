local cap_sdk = require 'services.hal.sdk.cap'
local errors = require 'services.ui.errors'

local M = {}

local function update_call(conn, payload, timeout)
    return conn:call({ 'cmd', 'update', 'job', 'create' }, payload, { timeout = timeout or 10.0 })
end

local function update_do(conn, payload, timeout)
    return conn:call({ 'cmd', 'update', 'job', 'do' }, payload, { timeout = timeout or 10.0 })
end

local function update_get(conn, payload, timeout)
    return conn:call({ 'cmd', 'update', 'job', 'get' }, payload, { timeout = timeout or 10.0 })
end

local function update_list(conn, timeout)
    return conn:call({ 'cmd', 'update', 'job', 'list' }, {}, { timeout = timeout or 10.0 })
end

function M.create(ctx, session_id, payload)
    local rec, err = ctx.require_session(session_id)
    if not rec then return nil, err end
    payload = type(payload) == 'table' and payload or {}
    if type(payload.source) == 'table' and payload.source.kind == 'upload' then
        payload.options = type(payload.options) == 'table' and payload.options or {}
        if payload.options.auto_start == nil then payload.options.auto_start = true end
        if payload.options.auto_commit == nil then payload.options.auto_commit = true end
    end
    local out, cerr = ctx.with_user_conn(rec.principal, { ui = { op = 'update_create' } }, function(user_conn)
        return update_call(user_conn, payload)
    end)
    if out == nil then return nil, cerr or errors.upstream('update_create failed') end
    if type(out) == 'table' and type(out.job) == 'table' and type(payload) == 'table' and type(payload.source) == 'table' and payload.source.kind == 'upload' then
        out.upload = out.upload or { required = true }
        out.upload.method = 'POST'
        out.upload.path = '/api/update/jobs/' .. tostring(out.job.job_id) .. '/artifact'
    end
    return out, nil
end

function M.get(ctx, session_id, job_id)
    local rec, err = ctx.require_session(session_id)
    if not rec then return nil, err end
    local out, cerr = ctx.with_user_conn(rec.principal, { ui = { op = 'update_get', job_id = job_id } }, function(user_conn)
        return update_get(user_conn, { job_id = job_id })
    end)
    if out == nil then return nil, cerr or errors.upstream('update_get failed') end
    return out, nil
end

function M.list(ctx, session_id)
    local rec, err = ctx.require_session(session_id)
    if not rec then return nil, err end
    local out, cerr = ctx.with_user_conn(rec.principal, { ui = { op = 'update_list' } }, function(user_conn)
        return update_list(user_conn)
    end)
    if out == nil then return nil, cerr or errors.upstream('update_list failed') end
    return out, nil
end

function M.do_job(ctx, session_id, job_id, payload)
    local rec, err = ctx.require_session(session_id)
    if not rec then return nil, err end
    if type(payload) ~= 'table' then return nil, errors.bad_request('payload must be a table') end
    local req = {}
    for k, v in pairs(payload) do req[k] = v end
    req.job_id = job_id
    local out, cerr = ctx.with_user_conn(rec.principal, { ui = { op = 'update_do', job_id = job_id, action = req.op } }, function(user_conn)
        return update_do(user_conn, req)
    end)
    if out == nil then return nil, cerr or errors.upstream('update_do failed') end
    return out, nil
end

function M.upload_artifact(ctx, session_id, job_id, stream, req_headers)
    local rec, err = ctx.require_session(session_id)
    if not rec then return nil, err end
    local content_length = tonumber(req_headers:get('content-length'))
    local name = req_headers:get('x-artifact-name')
    local version = req_headers:get('x-artifact-version')
    local build = req_headers:get('x-artifact-build')
    local checksum = req_headers:get('x-artifact-checksum')

    local out, cerr = ctx.with_user_conn(rec.principal, { ui = { op = 'update_upload', job_id = job_id } }, function(user_conn)
        local artifact_cap = cap_sdk.new_cap_ref(user_conn, 'artifact_store', 'main')
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
        local offset = 0
        while true do
            local chunk, rerr = stream:get_body_chars(64 * 1024)
            if chunk == nil then
                pcall(function() sink:abort() end)
                update_do(user_conn, { op = 'upload_failed', job_id = job_id, error = tostring(rerr or 'body_read_failed') }, 5.0)
                return nil, errors.bad_request('body_read_failed: ' .. tostring(rerr or 'body_read_failed'))
            end
            if chunk == '' then break end
            local ok, werr = sink:write_chunk(offset, chunk)
            if not ok then
                pcall(function() sink:abort() end)
                update_do(user_conn, { op = 'upload_failed', job_id = job_id, error = tostring(werr or 'sink_write_failed') }, 5.0)
                return nil, errors.from(werr or 'sink_write_failed', 502)
            end
            offset = offset + #chunk
            update_do(user_conn, { op = 'upload_progress', job_id = job_id, sent = offset, total = content_length }, 5.0)
        end
        local artefact, commit_err = sink:commit()
        if not artefact then
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
        if attached == nil then return nil, atterr or errors.upstream('attach_artifact failed') end
        return { ok = true, job = attached.job, artifact = { ref = artefact:ref(), size = desc.size, checksum = desc.checksum } }, nil
    end)
    if out == nil then return nil, cerr or errors.upstream('update_upload failed') end
    return out, nil
end

return M
