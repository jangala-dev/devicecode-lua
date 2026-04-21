local safe = require 'coxpcall'

local M = {}
local Publish = {}
Publish.__index = Publish

local function retain_best_effort(conn, topic, payload)
    safe.pcall(function() conn:retain(topic, payload) end)
end

function M.new(ctx)
    return setmetatable({ ctx = ctx }, Publish)
end

function Publish:publish_job_only(job)
    if not job then return end
    local ctx = self.ctx
    retain_best_effort(ctx.conn, ctx.projection.job_topic(job.job_id), { job = ctx.projection.public_job(job) })
end

function Publish:flush_publications()
    local ctx = self.ctx
    ctx.store_sync.flush_jobs(ctx.repo, ctx.state, ctx.on_store_error)
    for _, id in ipairs(ctx.state.store.order) do
        local job = ctx.state.store.jobs[id]
        if job then
            retain_best_effort(ctx.conn, ctx.projection.job_topic(id), { job = ctx.projection.public_job(job) })
        end
    end
    if ctx.state.summary_dirty then
        retain_best_effort(ctx.conn, ctx.projection.summary_topic(), ctx.projection.summary_payload(ctx.state))
        ctx.model.set_summary_clean(ctx.state)
    end
end

return M
