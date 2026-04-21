local cap_sdk = require 'services.hal.sdk.cap'
local safe = require 'coxpcall'
local uuid = require 'uuid'

local M = {}
local Commands = {}
Commands.__index = Commands

function M.new(ctx)
    return setmetatable({ ctx = ctx }, Commands)
end

function Commands:artifact_policy_for_component(component)
    local ctx = self.ctx
    return ctx.state.cfg.artifacts.policies[component] or ctx.state.cfg.artifacts.default_policy or 'prefer_durable'
end

function Commands:artifact_snapshot(artefact)
    if type(artefact) ~= 'table' or type(artefact.describe) ~= 'function' then
        return nil, 'invalid_artefact'
    end
    local rec = artefact:describe()
    if type(rec) ~= 'table' then return nil, 'invalid_artefact_record' end
    return rec, nil
end

function Commands:artifact_open(ref)
    local ctx = self.ctx
    local opts_ = assert(cap_sdk.args.new.ArtifactStoreOpenOpts(ref))
    local reply, err = ctx.artifact_cap:call_control('open', opts_)
    if not reply then return nil, err end
    if reply.ok ~= true then return nil, reply.reason end
    return reply.reason, nil
end

function Commands:artifact_delete(ref)
    local ctx = self.ctx
    local opts_ = assert(cap_sdk.args.new.ArtifactStoreDeleteOpts(ref))
    local reply, err = ctx.artifact_cap:call_control('delete', opts_)
    if not reply then return nil, err end
    if reply.ok ~= true then return nil, reply.reason end
    return true, nil
end

function Commands:artifact_import_path(path, component, metadata)
    local ctx = self.ctx
    local meta = { kind = 'update', component = component, metadata = metadata }
    local opts_ = assert(cap_sdk.args.new.ArtifactStoreImportPathOpts(path, meta, self:artifact_policy_for_component(component)))
    local reply, err = ctx.artifact_cap:call_control('import_path', opts_)
    if not reply then return nil, nil, err end
    if reply.ok ~= true then return nil, nil, reply.reason end
    local artefact = reply.reason
    local rec, rerr = self:artifact_snapshot(artefact)
    if not rec then return nil, nil, rerr end
    return artefact:ref(), rec, nil
end

function Commands:resolve_job_artifact(payload)
    local component = assert(payload.component, 'component required')
    local artifact = payload.artifact
    if type(artifact) ~= 'table' then return nil, nil, 'artifact_required' end

    if artifact.kind == 'path' then
        if type(artifact.path) ~= 'string' or artifact.path == '' then return nil, nil, 'invalid_artifact_path' end
        return self:artifact_import_path(artifact.path, component, payload.metadata)
    elseif artifact.kind == 'ref' then
        if type(artifact.ref) ~= 'string' or artifact.ref == '' then return nil, nil, 'invalid_artifact_ref' end
        local artefact, derr = self:artifact_open(artifact.ref)
        if not artefact then return nil, nil, derr end
        local desc, derr2 = self:artifact_snapshot(artefact)
        if not desc then return nil, nil, derr2 end
        return artifact.ref, desc, nil
    end

    return nil, nil, 'invalid_artifact_kind'
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
    local artifact_ref, artifact_meta, aerr = self:resolve_job_artifact(payload)
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

function Commands:handle_create(req)
    local payload = req.payload or {}
    local job, jerr = self:create_job(payload)
    if not job then
        req:fail(jerr)
        return
    end

    if job.auto_start then
        local ok, aerr = self.ctx.model.can_activate(self.ctx.state, job)
        if not ok then
            req:fail(aerr)
            return
        end
        self.ctx.patch_job(job, { state = 'staging', stage = 'validating_artifact', next_step = 'stage', error = nil })
        local wok, werr = self.ctx.runtime:spawn_runner('stage', job)
        if not wok then
            self.ctx.patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil })
            req:fail(tostring(werr))
            return
        end
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
    elseif not job then
        req:fail('unknown_job')
    elseif op == 'start' then
        if job.state ~= 'created' then
            req:fail('job_not_startable')
        else
            local ok, aerr = ctx.model.can_activate(ctx.state, job)
            if not ok then
                req:fail(aerr)
            else
                ctx.patch_job(job, { state = 'staging', stage = 'validating_artifact', next_step = 'stage', error = nil })
                local wok, werr = ctx.runtime:spawn_runner('stage', job)
                if not wok then
                    ctx.patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil })
                    req:fail(tostring(werr))
                else
                    req:reply({ ok = true, job = ctx.projection.public_job(job) })
                end
            end
        end
    elseif op == 'commit' then
        if job.state ~= 'awaiting_commit' then
            req:fail('job_not_committable')
        else
            local ok, aerr = ctx.model.can_activate(ctx.state, job)
            if not ok then
                req:fail(aerr)
            else
                ctx.patch_job(job, { state = 'awaiting_return', stage = 'commit_sent', next_step = 'reconcile', error = nil }, { runtime_merge = {
                    awaiting_return_run_id = ctx.service_run_id,
                    awaiting_return_mono = ctx.now(),
                } })
                ctx.store_sync.flush_jobs(ctx.repo, ctx.state, ctx.on_store_error)
                local wok, werr = ctx.runtime:spawn_runner('commit', job)
                if not wok then
                    ctx.patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil })
                    req:fail(tostring(werr))
                else
                    req:reply({ ok = true, job = ctx.projection.public_job(job) })
                end
            end
        end
    elseif op == 'cancel' then
        if ctx.model.ACTIVE_STATES[job.state] then
            req:fail('job_active')
        elseif ctx.model.TERMINAL_STATES[job.state] then
            req:fail('job_terminal')
        elseif job.state ~= 'created' and job.state ~= 'awaiting_commit' then
            req:fail('job_not_cancellable')
        else
            ctx.patch_job(job, { state = 'cancelled', next_step = nil, error = nil })
            req:reply({ ok = true, job = ctx.projection.public_job(job) })
        end
    elseif op == 'retry' then
        if not ctx.model.job_actions(job).retry then
            req:fail('job_not_retryable')
        else
            local new_job, rerr = self:clone_job_for_retry(job)
            if not new_job then req:fail(rerr) else req:reply({ ok = true, job = ctx.projection.public_job(new_job) }) end
        end
    elseif op == 'discard' then
        if not ctx.model.is_terminal(job.state) then
            req:fail('job_not_discardable')
        else
            if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
                ctx.release_artifact_if_present(job)
            end
            local _ = ctx.store_sync.delete_job(ctx.repo, job.job_id)
            ctx.model.remove_job(ctx.state, job.job_id)
            safe.pcall(function() ctx.conn:unretain(ctx.projection.job_topic(job.job_id)) end)
            ctx.changed:signal()
            req:reply({ ok = true })
        end
    else
        req:fail('invalid_op')
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
