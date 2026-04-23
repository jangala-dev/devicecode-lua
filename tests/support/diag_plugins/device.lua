local device_diag = require 'tests.support.device_diag'

return {
  name = 'device',
  topic_groups = {
    { label = 'device', topic = { 'state', 'device', '#' } },
    { label = 'dcmd', topic = { 'cmd', 'device', '#' } },
  },
  section = function(helper, opts)
    opts = opts or {}
    local conn = opts.conn

    return {
      render = function()
        return device_diag.render(helper.shallow_merge({
          service_fn = opts.service_fn or opts.device_service_fn or (conn and helper.retained_fn(conn, { 'svc', 'device', 'status' }) or nil),
          summary_fn = opts.summary_fn or opts.device_summary_fn or (conn and helper.retained_fn(conn, { 'state', 'device' }) or nil),
          cm5_fn = opts.cm5_fn or (conn and helper.retained_fn(conn, { 'state', 'device', 'component', opts.cm5_component or 'cm5' }) or nil),
          mcu_fn = opts.mcu_fn or (conn and helper.retained_fn(conn, { 'state', 'device', 'component', opts.mcu_component or 'mcu' }) or nil),
          extra_fn = opts.extra_fn or opts.device_extra_fn,
        }, opts))
      end,
    }
  end,
}
