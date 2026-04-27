return function(helper, opts)
  opts = opts or {}
  local conn = assert(opts.conn, 'ui_stack profile requires opts.conn')
  return {
    stack = helper.shallow_merge({ ui = true, config = true, obs = true, rpc = true, max_records = opts.max_records }, opts.stack),
    plugins = {
      { name = 'ui', opts = helper.shallow_merge({ conn = conn }, opts.ui) },
    },
  }
end
