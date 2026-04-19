
local M = {}

function M.new(opts)
    opts = opts or {}
    local component = opts.component or 'cm5'
    local timeout_prepare = opts.timeout_prepare or 10.0
    local timeout_stage = opts.timeout_stage or 30.0
    local timeout_commit = opts.timeout_commit or 10.0

    local backend = {}

    local function device_call(conn, op_name, args, timeout)
        return conn:call({ 'cmd', 'device', 'component', 'update' }, {
            component = component,
            op = op_name,
            args = args or {},
            timeout = timeout,
        }, { timeout = timeout })
    end

    function backend:status(conn)
        return conn:call({ 'cmd', 'device', 'component', 'status' }, { component = component }, { timeout = timeout_prepare })
    end

    function backend:prepare(conn, job)
        return device_call(conn, 'prepare', {
            target = job.target,
            metadata = job.metadata,
        }, timeout_prepare)
    end

    function backend:stage(conn, job)
        return device_call(conn, 'stage', {
            artifact = job.artifact,
            metadata = job.metadata,
            expected_version = job.expected_version,
        }, timeout_stage)
    end

    function backend:commit(conn, job)
        return device_call(conn, 'commit', {
            mode = job.target,
            metadata = job.metadata,
        }, timeout_commit)
    end

    function backend:reconcile(conn, job)
        local value, err = self:status(conn)
        if value == nil then return nil, err end
        local state = value.state or value

        -- Important: expected_version is only a staged/target marker, not proof
        -- that the new software is actually running. Reconciliation must only
        -- succeed from observed running-version state after return.
        local version = type(state) == 'table' and (state.fw_version or state.version) or nil
        local phase = type(state) == 'table' and state.state or nil

        if job.expected_version and version == job.expected_version and (phase == nil or phase == 'running' or phase == 'idle' or phase == 'ready') then
            return { done = true, success = true, version = version, raw = state }, nil
        end
        return { done = false, raw = state }, nil
    end

    return backend
end

return M
