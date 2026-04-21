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
    if not ctx.uploads then return nil, errors.unavailable('upload manager unavailable') end
    return ctx.uploads:upload_for_job(session_id, job_id, stream, req_headers)
end

return M
