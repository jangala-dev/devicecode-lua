local M = {}

function M.normalise_persisted(state, now_mono, service_run_id, model)
    return model.adopt_persisted_jobs(state, now_mono, service_run_id)
end

return M
