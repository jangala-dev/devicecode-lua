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
        reconcile = function(component, job)
            local sw = type(component) == 'table' and component.software or nil
            local upd = type(component) == 'table' and component.updater or nil
            local version = type(sw) == 'table' and sw.version or nil
            local build = type(sw) == 'table' and sw.build or nil
            local boot_id = type(sw) == 'table' and sw.boot_id or nil
            local phase = type(upd) == 'table' and upd.state or nil
            local last_error = type(upd) == 'table' and upd.last_error or nil
            if phase == 'failed' or phase == 'rollback_detected' then
                return { done = true, success = false, version = version, build = build, boot_id = boot_id, error = tostring(last_error or phase), raw = component }
            end
            if job.expected_version and version == job.expected_version and (phase == nil or phase == 'running' or phase == 'idle' or phase == 'ready') then
                return { done = true, success = true, version = version, build = build, boot_id = boot_id, raw = component }
            end
            return { done = false, version = version, build = build, boot_id = boot_id, raw = component }
        end,
    }
end

return M
