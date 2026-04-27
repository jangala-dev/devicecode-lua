local fabric_diag = require 'tests.support.fabric_diag'

return {
  name = 'fabric',
  topic_groups = {
    { label = 'fabric', topic = { 'state', 'fabric', '#' } },
    { label = 'member', topic = { 'raw', 'member', '#' } },
    { label = 'mcmd', topic = { 'cmd', 'member', '#' } },
  },
  section = function(helper, opts)
    opts = opts or {}
    local conn = opts.conn
    local link_id = opts.link_id or 'cm5-uart-mcu'
    local member_id = opts.member_id or 'mcu'

    return {
      render = function()
        return fabric_diag.render(helper.shallow_merge({
          service_fn = opts.service_fn or opts.fabric_service_fn or (conn and helper.retained_fn(conn, { 'svc', 'fabric', 'status' }) or nil),
          summary_fn = opts.summary_fn or opts.fabric_summary_fn or (conn and helper.retained_fn(conn, { 'state', 'fabric' }) or nil),
          session_fn = opts.session_fn or (conn and helper.retained_fn(conn, { 'state', 'fabric', 'link', link_id, 'session' }) or nil),
          transfer_fn = opts.transfer_fn or (conn and helper.retained_fn(conn, { 'state', 'fabric', 'link', link_id, 'transfer' }) or nil),
          member_fn = opts.member_fn or (conn and helper.retained_fn(conn, { 'raw', 'member', member_id, 'state', 'updater' }) or nil),
          extra_fn = opts.extra_fn or opts.fabric_extra_fn,
        }, opts))
      end,
    }
  end,
}
