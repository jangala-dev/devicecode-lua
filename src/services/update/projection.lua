local model = require 'services.update.model'

local M = {}

local function copy_value(v)
    return model.copy_value(v)
end

function M.job_topic(id)
    return { 'state', 'update', 'jobs', id }
end

function M.summary_topic()
    return { 'state', 'update', 'summary' }
end

function M.public_job(job)
    local staged_meta = type(job.staged_meta) == 'table' and job.staged_meta or nil
    local runtime = type(job.runtime) == 'table' and job.runtime or {}
    return {
        job_id = job.job_id,
        component = job.component,
        source = {
            offer_id = job.offer_id,
            kind = job.source_kind,
        },
        artifact = {
            ref = job.artifact_ref,
            meta = copy_value(job.artifact_meta),
            expected_version = job.expected_version,
            released_at = job.artifact_released_at,
            retention = staged_meta and staged_meta.artifact_retention or nil,
        },
        lifecycle = {
            state = job.state,
            stage = job.stage,
            next_step = job.next_step,
            created_seq = job.created_seq,
            updated_seq = job.updated_seq,
            created_mono = job.created_mono,
            updated_mono = job.updated_mono,
            error = job.error,
        },
        progress = copy_value(runtime.progress),
        observation = {
            pre_commit_boot_id = job.pre_commit_boot_id,
        },
        actions = model.job_actions(job),
        result = copy_value(job.result),
        metadata = copy_value(job.metadata),
    }
end

function M.public_jobs(state)
    local jobs = {}
    for _, id in ipairs(state.store.order) do
        local job = state.store.jobs[id]
        if job then jobs[#jobs + 1] = M.public_job(job) end
    end
    return jobs
end

function M.summary_payload(state)
    local counts = {
        total = #state.store.order,
        active = 0,
        terminal = 0,
        awaiting_commit = 0,
        awaiting_return = 0,
        created = 0,
        failed = 0,
        succeeded = 0,
    }
    local active = nil
    for _, id in ipairs(state.store.order) do
        local job = state.store.jobs[id]
        if job then
            local st = job.state
            counts[st] = (counts[st] or 0) + 1
            if model.is_active(st) then counts.active = counts.active + 1 end
            if model.is_terminal(st) then counts.terminal = counts.terminal + 1 end
            if state.active_job and state.active_job.job_id == id then
                active = {
                    job_id = id,
                    component = job.component,
                    state = st,
                    since = state.active_job.started_at,
                }
            end
        end
    end
    return {
        kind = 'update.summary',
        jobs = M.public_jobs(state),
        counts = counts,
        active = active,
        locks = copy_value(state.locks),
    }
end

return M
