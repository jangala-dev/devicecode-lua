return function(helper, opts)
  opts = opts or {}
  local conn = assert(opts.conn, 'device_stack profile requires opts.conn')
  return {
    stack = helper.shallow_merge({ device = true, max_records = opts.max_records }, opts.stack),
    plugins = {
      { name = 'device', opts = helper.shallow_merge({ conn = conn }, opts.device) },
    },
  }
end
