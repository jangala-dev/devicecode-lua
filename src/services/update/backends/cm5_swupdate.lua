local M = {}

function M.new(opts)
    opts = opts or {}
    local proxy = assert(opts.proxy_mod, 'proxy_mod required')
    return proxy.new {
        component = opts.component or 'cm5',
        artifact_retention = 'keep',
        timeout_prepare = opts.timeout_prepare or 10.0,
        timeout_stage = opts.timeout_stage or 30.0,
        timeout_commit = opts.timeout_commit or 10.0,
        reconcile = function(state, job)
            local version = type(state) == 'table' and (state.fw_version or state.version) or nil
            local phase = type(state) == 'table' and state.state or nil
            local last_error = type(state) == 'table' and state.last_error or nil
            if phase == 'failed' or phase == 'rollback_detected' then
                return { done = true, success = false, version = version, error = tostring(last_error or phase), raw = state }
            end
            if job.expected_version and version == job.expected_version and (phase == nil or phase == 'running' or phase == 'idle' or phase == 'ready') then
                return { done = true, success = true, version = version, raw = state }
            end
            return { done = false, raw = state }
        end,
    }
end

return M
