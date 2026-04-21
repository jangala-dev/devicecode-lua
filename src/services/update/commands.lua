local safe = require 'coxpcall'
local uuid = require 'uuid'

local M = {}
local Commands = {}
Commands.__index = Commands

function M.new(ctx)
    return setmetatable({ ctx = ctx }, Commands)
end

function Commands:create_job_from_spec(spec)
    local ctx = self.ctx
    local job = ctx.model.create_job(ctx.state, spec, ctx.now(), ctx.service_run_id)
    local ok, err = ctx.store_sync.save_job(ctx.repo, job)
    if not ok then return nil, err end
    ctx.changed:signal()
    return job, nil
end

function Commands:create_job(payload)
    local ctx = self.ctx
    local component = assert(payload.component, 'component required')
    if not ctx.state.cfg.components[component] then return nil, 'unknown_component' end
    local artifact_ref, artifact_meta, aerr = ctx.artifacts:resolve_job_artifact(payload)
    if aerr ~= nil then return nil, aerr end
    return self:create_job_from_spec {
        job_id = tostring(uuid.new()),
        offer_id = payload.offer_id,
        component = component,
        artifact_ref = artifact_ref,
        artifact_meta = artifact_meta,
        expected_version = payload.expected_version,
        metadata = type(payload.metadata) == 'table' and ctx.model.copy_value(payload.metadata) or nil,
        auto_start = (type(payload.options) == 'table' and payload.options.auto_start == true),
        auto_commit = (type(payload.options) == 'table' and payload.options.auto_commit == true),
    }
end

function Commands:clone_job_for_retry(src)
    local job, err = self:create_job_from_spec {
        job_id = tostring(uuid.new()),
        component = src.component,
        offer_id = src.offer_id,
        artifact_ref = src.artifact_ref,
        artifact_meta = src.artifact_meta,
        expected_version = src.expected_version,
        metadata = self.ctx.model.copy_value(src.metadata),
    }
    if not job then return nil, err end
    self.ctx.patch_job(src, { state = 'superseded', next_step = nil, error = nil })
    return job, nil
end

function Commands:start_job(job)
    local ctx = self.ctx
    if job.state ~= 'created' then return nil, 'job_not_startable' end
    local ok, aerr = ctx.model.can_activate(ctx.state, job)
    if not ok then return nil, aerr end
    ctx.patch_job(job, { state = 'staging', stage = 'validating_artifact', next_step = 'stage', error = nil })
    local wok, werr = ctx.runtime:spawn_runner('stage', job)
    if not wok then
        ctx.patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil })
        return nil, tostring(werr)
    end
    return ctx.projection.public_job(job), nil
end

function Commands:commit_job(job)
    local ctx = self.ctx
    if job.state ~= 'awaiting_commit' then return nil, 'job_not_committable' end
    local ok, aerr = ctx.model.can_activate(ctx.state, job)
    if not ok then return nil, aerr end
    ctx.enter_awaiting_return(job, 'commit_sent')
    ctx.store_sync.flush_jobs(ctx.repo, ctx.state, ctx.on_store_error)
    local wok, werr = ctx.runtime:spawn_runner('commit', job)
    if not wok then
        ctx.patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil })
        return nil, tostring(werr)
    end
    return ctx.projection.public_job(job), nil
end

function Commands:cancel_job(job)
    local ctx = self.ctx
    if ctx.model.ACTIVE_STATES[job.state] then return nil, 'job_active' end
    if ctx.model.TERMINAL_STATES[job.state] then return nil, 'job_terminal' end
    if job.state ~= 'created' and job.state ~= 'awaiting_commit' then return nil, 'job_not_cancellable' end
    ctx.patch_job(job, { state = 'cancelled', next_step = nil, error = nil })
    return ctx.projection.public_job(job), nil
end

function Commands:retry_job(job)
    if not self.ctx.model.job_actions(job).retry then return nil, 'job_not_retryable' end
    local new_job, rerr = self:clone_job_for_retry(job)
    if not new_job then return nil, rerr end
    return self.ctx.projection.public_job(new_job), nil
end

function Commands:discard_job(job)
    local ctx = self.ctx
    if not ctx.model.is_terminal(job.state) then return nil, 'job_not_discardable' end
    if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
        ctx.release_artifact_if_present(job)
    end
    local _ = ctx.store_sync.delete_job(ctx.repo, job.job_id)
    ctx.model.remove_job(ctx.state, job.job_id)
    safe.pcall(function() ctx.conn:unretain(ctx.projection.job_topic(job.job_id)) end)
    ctx.changed:signal()
    return { ok = true }, nil
end

function Commands:handle_create(req)
    local payload = req.payload or {}
    local job, jerr = self:create_job(payload)
    if not job then
        req:fail(jerr)
        return
    end

    if job.auto_start then
        local view, serr = self:start_job(job)
        if not view then
            req:fail(serr)
            return
        end
        req:reply({ ok = true, job = view })
        return
    end

    req:reply({ ok = true, job = self.ctx.projection.public_job(job) })
end

function Commands:handle_do(req)
    local ctx = self.ctx
    local payload = req.payload or {}
    local op = payload.op
    local job = ctx.state.store.jobs[payload.job_id]
    if type(op) ~= 'string' or op == '' then
        req:fail('invalid_op')
        return
    end
    if not job then
        req:fail('unknown_job')
        return
    end

    local value, err
    if op == 'start' then
        value, err = self:start_job(job)
        if value == nil then req:fail(err) else req:reply({ ok = true, job = value }) end
        return
    elseif op == 'commit' then
        value, err = self:commit_job(job)
        if value == nil then req:fail(err) else req:reply({ ok = true, job = value }) end
        return
    elseif op == 'cancel' then
        value, err = self:cancel_job(job)
        if value == nil then req:fail(err) else req:reply({ ok = true, job = value }) end
        return
    elseif op == 'retry' then
        value, err = self:retry_job(job)
        if value == nil then req:fail(err) else req:reply({ ok = true, job = value }) end
        return
    elseif op == 'discard' then
        value, err = self:discard_job(job)
        if value == nil then req:fail(err) else req:reply(value) end
        return
    else
        req:fail('invalid_op')
        return
    end
end

function Commands:handle_get(req)
    local job = self.ctx.state.store.jobs[(req.payload or {}).job_id]
    if not job then req:fail('unknown_job') else req:reply({ ok = true, job = self.ctx.projection.public_job(job) }) end
end

function Commands:handle_list(req)
    req:reply({ ok = true, jobs = self.ctx.projection.public_jobs(self.ctx.state) })
end

return M
