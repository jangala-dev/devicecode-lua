local M = {}

function M.new(opts)
    opts = opts or {}
    local proxy = assert(opts.proxy_mod, 'proxy_mod required')
    local component = opts.component or 'mcu'
    local timeout_prepare = opts.timeout_prepare or 10.0
    local timeout_stage = opts.timeout_stage or 60.0
    local timeout_commit = opts.timeout_commit or 10.0
    local transfer = type(opts.transfer) == 'table' and opts.transfer or {}
    local link_id = transfer.link_id or 'cm5-uart-mcu'
    local receiver = transfer.receiver
    local transfer_timeout = transfer.timeout_s or timeout_stage

    local backend = proxy.new {
        component = component,
        artifact_retention = 'release',
        timeout_prepare = timeout_prepare,
        timeout_stage = timeout_stage,
        timeout_commit = timeout_commit,
        reconcile = function(component_state, job)
            local sw = type(component_state) == 'table' and component_state.software or nil
            local upd = type(component_state) == 'table' and component_state.updater or nil
            local version = type(sw) == 'table' and sw.version or nil
            local build = type(sw) == 'table' and sw.build or nil
            local incarnation = type(sw) == 'table' and (sw.incarnation or sw.generation) or nil
            local boot_id = type(sw) == 'table' and sw.boot_id or nil
            local phase = type(upd) == 'table' and upd.state or nil
            local last_error = type(upd) == 'table' and upd.last_error or nil
            if phase == 'failed' or phase == 'rollback_detected' then
                return { done = true, success = false, version = version, build = build, incarnation = incarnation, boot_id = boot_id, error = tostring(last_error or phase), raw = component_state }
            end
            if job.expected_version and version == job.expected_version then
                local boot_changed = (job.pre_commit_boot_id ~= nil and boot_id ~= nil and boot_id ~= job.pre_commit_boot_id)
                local inc_changed = (job.pre_commit_incarnation ~= nil and incarnation ~= nil and incarnation ~= job.pre_commit_incarnation)
                if boot_changed or inc_changed or (phase == 'running' or phase == 'ready' or phase == 'idle' or phase == nil) then
                    return { done = true, success = true, version = version, build = build, incarnation = incarnation, boot_id = boot_id, raw = component_state }
                end
            end
            return { done = false, version = version, build = build, incarnation = incarnation, boot_id = boot_id, raw = component_state }
        end,
    }

    function backend:stage(conn, job, source)
        if source == nil then return nil, 'missing_source' end
        local payload = {
            op = 'send_blob',
            link_id = link_id,
            source = source,
            meta = {
                kind = 'firmware',
                component = component,
                version = job.expected_version,
                job_id = job.job_id,
                size = type(source.size) == 'function' and source:size() or nil,
                checksum = type(source.checksum) == 'function' and source:checksum() or nil,
                metadata = job.metadata,
            },
        }
        if type(receiver) == 'table' then payload.receiver = receiver end
        local value, err = conn:call({ 'cmd', 'fabric', 'transfer' }, payload, { timeout = transfer_timeout })
        if value == nil then return nil, err end
        if type(value) ~= 'table' then value = { ok = true } end
        if value.artifact_retention == nil then value.artifact_retention = 'release' end
        value.staged = true
        return value, nil
    end

    return backend
end

return M
