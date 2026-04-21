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
        reconcile = function(state, job)
            local version = type(state) == 'table' and (state.fw_version or state.version) or nil
            local incarnation = type(state) == 'table' and (state.incarnation or state.generation) or nil
            local phase = type(state) == 'table' and (state.updater_state or state.state) or nil
            local last_error = type(state) == 'table' and state.last_error or nil
            if phase == 'failed' or phase == 'rollback_detected' then
                return { done = true, success = false, version = version, incarnation = incarnation, error = tostring(last_error or phase), raw = state }
            end
            if job.expected_version and version == job.expected_version then
                return { done = true, success = true, version = version, incarnation = incarnation, raw = state }
            end
            if job.pre_commit_incarnation ~= nil and incarnation ~= nil and incarnation ~= job.pre_commit_incarnation then
                if type(state) == 'table' and (phase == 'running' or phase == 'ready') then
                    return { done = true, success = true, version = version, incarnation = incarnation, raw = state }
                end
                return { done = false, raw = state }
            end
            return { done = false, raw = state }
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
