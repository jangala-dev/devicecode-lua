local ui_diag = require 'tests.support.ui_diag'

return {
  name = 'ui',
  topic_groups = {
    { label = 'ui', topic = { 'state', 'ui', '#' } },
  },
  section = function(helper, opts)
    opts = opts or {}
    local conn = opts.conn

    return {
      render = function()
        return ui_diag.render(helper.shallow_merge({
          main_fn = opts.main_fn or (conn and helper.retained_fn(conn, { 'state', 'ui', 'main' }) or nil),
          config_net_fn = opts.config_net_fn or (conn and helper.retained_fn(conn, { 'cfg', 'net' }) or nil),
          services_fn = opts.services_fn,
          fabric_fn = opts.fabric_fn or (conn and helper.retained_fn(conn, { 'state', 'fabric' }) or nil),
          extra_fn = opts.extra_fn or opts.ui_extra_fn,
        }, opts))
      end,
    }
  end,
}
