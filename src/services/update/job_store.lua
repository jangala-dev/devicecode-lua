local cap_sdk = require 'services.hal.sdk.cap'

local M = {}

local function copy_job(job)
    local out = {}
    for k, v in pairs(job) do out[k] = v end
    return out
end

local function sorted_order(jobs)
    local ids = {}
    for id in pairs(jobs) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        local ja, jb = jobs[a], jobs[b]
        local ta = (ja and (ja.created_seq or ja.created_mono)) or 0
        local tb = (jb and (jb.created_seq or jb.created_mono)) or 0
        if ta == tb then return tostring(a) < tostring(b) end
        return ta < tb
    end)
    return ids
end

function M.open(store_cap, opts)
    opts = opts or {}
    local namespace = opts.namespace or 'update/jobs'

    local repo = {}

    local function call(method, args)
        return store_cap:call_control(method, args)
    end

    function repo:load_all()
        local list_opts = assert(cap_sdk.args.new.ControlStoreListOpts(namespace))
        local reply, err = call('list', list_opts)
        if not reply then return nil, err end
        if reply.ok ~= true then return nil, reply.reason end

        local jobs = {}
        local keys = type(reply.reason) == 'table' and reply.reason.keys or {}
        for _, key in ipairs(keys or {}) do
            local get_opts = assert(cap_sdk.args.new.ControlStoreGetOpts(namespace, key))
            local r, gerr = call('get', get_opts)
            if r and r.ok == true and type(r.reason) == 'table' then
                jobs[key] = r.reason
            elseif not r then
                return nil, gerr
            end
        end
        return { jobs = jobs, order = sorted_order(jobs) }, nil
    end

    function repo:save_job(job)
        if type(job) ~= 'table' or type(job.job_id) ~= 'string' or job.job_id == '' then
            return nil, 'invalid_job'
        end
        local put_opts = assert(cap_sdk.args.new.ControlStorePutOpts(namespace, job.job_id, copy_job(job)))
        local reply, err = call('put', put_opts)
        if not reply then return nil, err end
        if reply.ok ~= true then return nil, reply.reason end
        return true, nil
    end

    function repo:delete_job(job_id)
        if type(job_id) ~= 'string' or job_id == '' then return nil, 'invalid_job_id' end
        local del_opts = assert(cap_sdk.args.new.ControlStoreDeleteOpts(namespace, job_id))
        local reply, err = call('delete', del_opts)
        if not reply then return nil, err end
        if reply.ok ~= true then return nil, reply.reason end
        return true, nil
    end

    return repo
end

return M
