local fibers = require 'fibers'
local sleep = require 'fibers.sleep'

local M = {}

local function emit(tx, ev)
    tx:send(ev)
end

function M.run_stage(conn, job, backend, tx, source)
    local status_before = backend:status(conn)
    local sw = type(status_before) == 'table' and status_before.software or nil
    local pre_commit_incarnation = nil
    local pre_commit_boot_id = nil
    if type(sw) == 'table' then
        pre_commit_incarnation = sw.incarnation or sw.generation
        pre_commit_boot_id = sw.boot_id
    end

    local prep, perr = backend:prepare(conn, job)
    if prep == nil then
        emit(tx, { tag = 'failed', job_id = job.job_id, err = tostring(perr or 'prepare_failed') })
        return
    end

    local staged, serr = backend:stage(conn, job, source)
    if staged == nil then
        emit(tx, { tag = 'failed', job_id = job.job_id, err = tostring(serr or 'stage_failed') })
        return
    end

    emit(tx, {
        tag = 'staged',
        job_id = job.job_id,
        staged = staged,
        pre_commit_incarnation = pre_commit_incarnation,
        pre_commit_boot_id = pre_commit_boot_id,
    })
end

local function evaluate_once(conn, job, backend, tx, observe)
    local facts = observe and observe.facts_for and observe:facts_for(job.component) or nil
    if backend.status and facts == nil then
        local current = backend:status(conn)
        if current ~= nil then
            if observe and observe.note_component then observe:note_component(job.component, current) end
            facts = observe and observe.facts_for and observe:facts_for(job.component) or current
        end
    end
    local result = backend.evaluate and backend:evaluate(job, facts) or nil
    if result ~= nil then
        if result.done and result.success then
            emit(tx, { tag = 'reconciled_success', job_id = job.job_id, result = result })
            return true
        elseif result.done then
            emit(tx, { tag = 'reconciled_failure', job_id = job.job_id, result = result, err = tostring(result.error or 'failed') })
            return true
        else
            emit(tx, { tag = 'reconcile_progress', job_id = job.job_id, result = result })
        end
    end
    return false
end

function M.run_commit(conn, job, backend, tx, _reconcile_cfg)
    local committed, cerr = backend:commit(conn, job)
    if committed == nil then
        emit(tx, { tag = 'failed', job_id = job.job_id, err = tostring(cerr or 'commit_failed') })
        return
    end
    emit(tx, { tag = 'commit_started', job_id = job.job_id, result = committed })
end

function M.run_reconcile(conn, job, backend, tx, reconcile_cfg, observe)
    local timeout_s = reconcile_cfg.timeout_s
    local deadline = fibers.now() + timeout_s

    if evaluate_once(conn, job, backend, tx, observe) then return end

    local seen = observe and observe:version() or 0
    while true do
        local remaining = deadline - fibers.now()
        if remaining <= 0 then
            emit(tx, { tag = 'timed_out', job_id = job.job_id, err = 'timeout' })
            return
        end
        local which, v = fibers.perform(fibers.named_choice({
            changed = observe:changed_op(seen),
            timeout = sleep.sleep_op(remaining):wrap(function() return true end),
        }))
        if which == 'timeout' then
            emit(tx, { tag = 'timed_out', job_id = job.job_id, err = 'timeout' })
            return
        end
        if v ~= nil then seen = v end
        if evaluate_once(conn, job, backend, tx, observe) then return end
    end
end

return M
