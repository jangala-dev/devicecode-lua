local fibers = require 'fibers'
local await_mod = require 'services.update.await'

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

function M.run_commit(conn, job, backend, tx, _reconcile_cfg)
    local committed, cerr = backend:commit(conn, job)
    if committed == nil then
        emit(tx, { tag = 'failed', job_id = job.job_id, err = tostring(cerr or 'commit_failed') })
        return
    end
    emit(tx, { tag = 'commit_started', job_id = job.job_id, result = committed })
end

local function current_version(observe)
    return (observe and observe.version and observe:version()) or 0
end

function M.run_reconcile(conn, job, backend, tx, reconcile_cfg, observe)
    local outcome, result = await_mod.until_changed_or_timeout({
        timeout_s = reconcile_cfg.timeout_s,
        version = function() return current_version(observe) end,
        changed_op = function(seen) return observe:changed_op(seen) end,
        evaluate = function()
            local facts = observe and observe.facts_for and observe:facts_for(job.component) or nil
            return backend.evaluate and backend:evaluate(job, facts) or nil
        end,
        on_progress = function(progress)
            emit(tx, { tag = 'reconcile_progress', job_id = job.job_id, result = progress })
        end,
    })

    if outcome == 'success' then
        emit(tx, { tag = 'reconciled_success', job_id = job.job_id, result = result })
    elseif outcome == 'failure' then
        emit(tx, { tag = 'reconciled_failure', job_id = job.job_id, result = result, err = tostring(result and result.error or 'failed') })
    else
        emit(tx, { tag = 'timed_out', job_id = job.job_id, err = 'timeout' })
    end
end

return M
