local M = {}

function M.new(opts)
    opts = opts or {}
    local proxy = assert(opts.proxy_mod, 'proxy_mod required')
    return proxy.new {
        component = opts.component or 'mcu',
        artifact_retention = 'release',
        timeout_prepare = opts.timeout_prepare or 10.0,
        timeout_stage = opts.timeout_stage or 60.0,
        timeout_commit = opts.timeout_commit or 10.0,
        reconcile = function(state, job)
            local version = type(state) == 'table' and (state.fw_version or state.version) or nil
            local incarnation = type(state) == 'table' and (state.incarnation or state.generation) or nil
            if job.expected_version and version == job.expected_version then
                return { done = true, success = true, version = version, incarnation = incarnation, raw = state }
            end
            if job.pre_commit_incarnation ~= nil and incarnation ~= nil and incarnation ~= job.pre_commit_incarnation then
                if type(state) == 'table' and (state.updater_state == 'running' or state.state == 'running' or state.state == 'ready') then
                    return { done = true, success = true, version = version, incarnation = incarnation, raw = state }
                end
                return { done = false, raw = state }
            end
            return { done = false, raw = state }
        end,
    }
end

return M
