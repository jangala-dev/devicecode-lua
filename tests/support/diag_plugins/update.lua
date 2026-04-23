local update_diag = require 'tests.support.update_diag'

return {
  name = 'update',
  topic_groups = {
    { label = 'update', topic = { 'state', 'update', '#' } },
    { label = 'ucmd', topic = { 'cmd', 'update', '#' } },
  },
  section = function(helper, opts)
    opts = opts or {}
    local conn = opts.conn

    return {
      render = function()
        return update_diag.render(helper.shallow_merge({
          service_fn = opts.service_fn or (conn and helper.retained_fn(conn, { 'svc', 'update', 'status' }) or nil),
          summary_fn = opts.summary_fn or (conn and helper.retained_fn(conn, { 'state', 'update', 'summary' }) or nil),
          jobs_fn = opts.jobs_fn,
          active_job_fn = opts.active_job_fn,
          store_fn = opts.store_fn or function() return opts.control and opts.control.namespaces['update/jobs'] or nil end,
          artifacts_fn = opts.artifacts_fn or function() return opts.artifacts and opts.artifacts.artifacts or nil end,
          backend_fn = opts.backend_fn,
          extra_fn = opts.extra_fn or opts.update_extra_fn,
        }, opts))
      end,
    }
  end,
}
