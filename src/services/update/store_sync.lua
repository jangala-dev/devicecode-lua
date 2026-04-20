local M = {}

function M.load(repo)
    return repo:load_all()
end

function M.save_job(repo, job)
    return repo:save_job(job)
end

function M.delete_job(repo, job_id)
    return repo:delete_job(job_id)
end

function M.flush_jobs(repo, state, on_error)
    local saved = false
    for _, id in ipairs(state.store.order) do
        if state.dirty_jobs[id] then
            local job = state.store.jobs[id]
            if job then
                local ok, err = repo:save_job(job)
                if not ok and on_error then on_error(id, err) end
            end
            state.dirty_jobs[id] = nil
            saved = true
        end
    end
    return saved
end

return M
