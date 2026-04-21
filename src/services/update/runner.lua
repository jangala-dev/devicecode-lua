local sleep = require 'fibers.sleep'

local M = {}

local function emit(tx, ev)
    tx:send(ev)
end

function M.run_stage(conn, job, backend, tx, source)
    local status_before = backend:status(conn)
    local status_before_state = (type(status_before) == 'table' and status_before.component and status_before.component.status) or (type(status_before) == 'table' and status_before.state) or status_before
    local pre_commit_incarnation = nil
    if type(status_before_state) == 'table' then
        pre_commit_incarnation = status_before_state.incarnation or status_before_state.generation
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
    })
end

local function reconcile_loop(conn, job, backend, tx, interval_s, timeout_s)
    local deadline = require('fibers').now() + timeout_s
    while true do
        local result, rerr = backend:reconcile(conn, job)
        if result ~= nil then
            if result.done and result.success then
                emit(tx, { tag = 'reconciled_success', job_id = job.job_id, result = result })
                return
            elseif result.done then
                emit(tx, { tag = 'reconciled_failure', job_id = job.job_id, result = result, err = tostring(result.error or rerr or 'failed') })
                return
            else
                emit(tx, { tag = 'reconcile_progress', job_id = job.job_id, result = result })
            end
        end
        if require('fibers').now() >= deadline then
            emit(tx, { tag = 'timed_out', job_id = job.job_id, err = tostring(rerr or 'timeout') })
            return
        end
        sleep.sleep(interval_s)
    end
end

function M.run_commit(conn, job, backend, tx, reconcile_cfg)
    local committed, cerr = backend:commit(conn, job)
    if committed == nil then
        emit(tx, { tag = 'failed', job_id = job.job_id, err = tostring(cerr or 'commit_failed') })
        return
    end
    emit(tx, { tag = 'commit_started', job_id = job.job_id, result = committed })
    reconcile_loop(conn, job, backend, tx, reconcile_cfg.interval_s, reconcile_cfg.timeout_s)
end

function M.run_reconcile(conn, job, backend, tx, reconcile_cfg)
    reconcile_loop(conn, job, backend, tx, reconcile_cfg.interval_s, reconcile_cfg.timeout_s)
end

return M
