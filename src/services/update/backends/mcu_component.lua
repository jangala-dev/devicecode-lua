
local M = {}

function M.new(opts)
    opts = opts or {}
    local component = opts.component or 'mcu'
    local timeout_prepare = opts.timeout_prepare or 10.0
    local timeout_stage = opts.timeout_stage or 60.0
    local timeout_commit = opts.timeout_commit or 10.0

    local backend = {}

    local function device_call(conn, op_name, args, timeout)
        return conn:call({ 'cmd', 'device', 'component', 'do' }, {
            component = component,
            action = op_name,
            args = args or {},
            timeout = timeout,
        }, { timeout = timeout })
    end

    function backend:status(conn)
        return conn:call({ 'cmd', 'device', 'component', 'get' }, { component = component }, { timeout = timeout_prepare })
    end

    function backend:prepare(conn, job)
        return device_call(conn, 'prepare_update', {
            target = job.component,
            metadata = job.metadata,
        }, timeout_prepare)
    end

    function backend:stage(conn, job)
        local value, err = device_call(conn, 'stage_update', {
            artifact_ref = job.artifact_ref,
            metadata = job.metadata,
            expected_version = job.expected_version,
        }, timeout_stage)
        if value == nil then return nil, err end
        if type(value) == 'table' and value.artifact_retention == nil then value.artifact_retention = 'release' end
        return value, nil
    end

    function backend:commit(conn, job)
        return device_call(conn, 'commit_update', {
            mode = job.component,
            metadata = job.metadata,
        }, timeout_commit)
    end

    function backend:reconcile(conn, job)
        local value, err = self:status(conn)
        if value == nil then return nil, err end
        local state = (type(value) == 'table' and value.component and value.component.status) or value.state or value
        local version = type(state) == 'table' and (state.fw_version or state.version) or nil
        local incarnation = type(state) == 'table' and (state.incarnation or state.generation) or nil
        if job.expected_version and version == job.expected_version then
            return { done = true, success = true, version = version, incarnation = incarnation, raw = state }, nil
        end
        if job.pre_commit_incarnation ~= nil and incarnation ~= nil and incarnation ~= job.pre_commit_incarnation then
            if type(state) == 'table' and (state.updater_state == 'running' or state.state == 'running' or state.state == 'ready') then
                return { done = true, success = true, version = version, incarnation = incarnation, raw = state }, nil
            end
            return { done = false, raw = state }, nil
        end
        return { done = false, raw = state }, nil
    end

    return backend
end

return M
