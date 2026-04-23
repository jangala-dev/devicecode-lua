return function(helper, opts)
  opts = opts or {}
  local conn = assert(opts.conn, 'update_stack profile requires opts.conn')
  return {
    stack = helper.shallow_merge({ update = true, device = true, fabric = true, max_records = opts.max_records }, opts.stack),
    plugins = {
      { name = 'update', opts = helper.shallow_merge({ conn = conn }, opts.update) },
      { name = 'device', opts = helper.shallow_merge({ conn = conn }, opts.device) },
      { name = 'fabric', opts = helper.shallow_merge({ conn = conn, link_id = opts.link_id, member_id = opts.member_id }, opts.fabric) },
    },
  }
end
