local checksum = require 'services.fabric.checksum'
local cjson    = require 'cjson.safe'

local M = {}

local function clone(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = clone(val) end
  return out
end

local function bind_reply_loop(scope, ep, handler)
  local ok, err = scope:spawn(function()
    while true do
      local req = ep:recv()
      if not req then return end
      local reply, ferr = handler(req.payload or {}, req)
      if reply == nil then req:fail(ferr or 'failed') else req:reply(reply) end
    end
  end)
  assert(ok, tostring(err))
end

function M.start_control_store_cap(scope, conn, backing)
  backing = backing or { namespaces = {}, max_record_bytes = 65536 }
  backing.namespaces = backing.namespaces or {}
  backing.max_record_bytes = backing.max_record_bytes or 65536

  conn:retain({ 'cap', 'control_store', 'update', 'state' }, 'added')
  conn:retain({ 'cap', 'control_store', 'update', 'meta' }, {
    offerings = { get = true, put = true, delete = true, list = true, status = true }
  })

  local function ns_table(ns)
    local t = backing.namespaces[ns]
    if not t then
      t = {}
      backing.namespaces[ns] = t
    end
    return t
  end

  local get_ep = conn:bind({ 'cap', 'control_store', 'update', 'rpc', 'get' }, { queue_len = 32 })
  local put_ep = conn:bind({ 'cap', 'control_store', 'update', 'rpc', 'put' }, { queue_len = 32 })
  local del_ep = conn:bind({ 'cap', 'control_store', 'update', 'rpc', 'delete' }, { queue_len = 32 })
  local list_ep = conn:bind({ 'cap', 'control_store', 'update', 'rpc', 'list' }, { queue_len = 32 })
  local status_ep = conn:bind({ 'cap', 'control_store', 'update', 'rpc', 'status' }, { queue_len = 32 })

  bind_reply_loop(scope, get_ep, function(payload)
    local ns = backing.namespaces[payload.ns]
    local value = ns and ns[payload.key] or nil
    if value == nil then return { ok = false, reason = 'not_found' } end
    return { ok = true, reason = clone(value) }
  end)

  bind_reply_loop(scope, put_ep, function(payload)
    local raw, err = cjson.encode(payload.value)
    if not raw then return { ok = false, reason = 'encode_failed:' .. tostring(err) } end
    if backing.max_record_bytes and #raw > backing.max_record_bytes then
      return { ok = false, reason = 'record_too_large' }
    end
    local ns = ns_table(payload.ns)
    ns[payload.key] = clone(payload.value)
    return { ok = true, reason = { ok = true } }
  end)

  bind_reply_loop(scope, del_ep, function(payload)
    local ns = ns_table(payload.ns)
    ns[payload.key] = nil
    return { ok = true, reason = { ok = true } }
  end)

  bind_reply_loop(scope, list_ep, function(payload)
    local ns = backing.namespaces[payload.ns] or {}
    local keys = {}
    for k in pairs(ns) do keys[#keys + 1] = k end
    table.sort(keys)
    return { ok = true, reason = { ns = payload.ns, keys = keys } }
  end)

  bind_reply_loop(scope, status_ep, function()
    return { ok = true, reason = { root = 'mem://control', max_record_bytes = backing.max_record_bytes } }
  end)

  return backing
end

function M.start_artifact_store_cap(scope, conn, backing)
  backing = backing or { artifacts = {}, next_id = 0, import_paths = {}, durable_enabled = true }
  backing.artifacts = backing.artifacts or {}
  backing.import_paths = backing.import_paths or {}
  if backing.durable_enabled == nil then backing.durable_enabled = true end

  conn:retain({ 'cap', 'artifact_store', 'main', 'state' }, 'added')
  conn:retain({ 'cap', 'artifact_store', 'main', 'meta' }, {
    offerings = {
      create = true, append = true, finalise = true, import_path = true,
      describe = true, delete = true, status = true,
    }
  })

  local function mkref()
    backing.next_id = (backing.next_id or 0) + 1
    return ('art-%d'):format(backing.next_id)
  end

  local function choose(policy)
    policy = policy or 'transient_only'
    if policy == 'require_durable' then
      if not backing.durable_enabled then return nil, 'durable_disabled' end
      return 'durable'
    elseif policy == 'prefer_durable' then
      return backing.durable_enabled and 'durable' or 'transient'
    elseif policy == 'transient_only' then
      return 'transient'
    end
    return nil, 'invalid_policy'
  end

  local function out(rec)
    local c = clone(rec)
    c.data = nil
    return c
  end

  local create_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'create' }, { queue_len = 32 })
  local append_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'append' }, { queue_len = 32 })
  local finalise_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'finalise' }, { queue_len = 32 })
  local import_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'import_path' }, { queue_len = 32 })
  local describe_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'describe' }, { queue_len = 32 })
  local delete_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'delete' }, { queue_len = 32 })
  local status_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'status' }, { queue_len = 32 })

  bind_reply_loop(scope, create_ep, function(payload)
    local durability, err = choose(payload.policy)
    if not durability then return { ok = false, reason = err } end
    local ref = mkref()
    local rec = {
      artifact_ref = ref,
      state = 'writing',
      durability = durability,
      size = 0,
      checksum = nil,
      meta = clone(payload.meta or {}),
      data = '',
      created_at = os.time(),
      updated_at = os.time(),
    }
    backing.artifacts[ref] = rec
    return { ok = true, reason = out(rec) }
  end)

  bind_reply_loop(scope, append_ep, function(payload)
    local rec = backing.artifacts[payload.artifact_ref]
    if not rec then return { ok = false, reason = 'not_found' } end
    if rec.state ~= 'writing' then return { ok = false, reason = 'artifact_not_writable' } end
    rec.data = rec.data .. (payload.data or '')
    rec.size = #rec.data
    rec.updated_at = os.time()
    return { ok = true, reason = out(rec) }
  end)

  bind_reply_loop(scope, finalise_ep, function(payload)
    local rec = backing.artifacts[payload.artifact_ref]
    if not rec then return { ok = false, reason = 'not_found' } end
    rec.state = 'ready'
    rec.size = #rec.data
    rec.checksum = checksum.digest_hex(rec.data)
    rec.updated_at = os.time()
    return { ok = true, reason = out(rec) }
  end)

  bind_reply_loop(scope, import_ep, function(payload)
    local data = backing.import_paths[payload.path]
    if type(data) ~= 'string' then return { ok = false, reason = 'not_found' } end
    local durability, err = choose(payload.policy)
    if not durability then return { ok = false, reason = err } end
    local ref = mkref()
    local rec = {
      artifact_ref = ref,
      state = 'ready',
      durability = durability,
      size = #data,
      checksum = checksum.digest_hex(data),
      meta = clone(payload.meta or {}),
      data = data,
      created_at = os.time(),
      updated_at = os.time(),
    }
    backing.artifacts[ref] = rec
    return { ok = true, reason = out(rec) }
  end)

  bind_reply_loop(scope, describe_ep, function(payload)
    local rec = backing.artifacts[payload.artifact_ref]
    if not rec then return { ok = false, reason = 'not_found' } end
    return { ok = true, reason = out(rec) }
  end)

  bind_reply_loop(scope, delete_ep, function(payload)
    backing.artifacts[payload.artifact_ref] = nil
    return { ok = true, reason = { ok = true } }
  end)

  bind_reply_loop(scope, status_ep, function()
    return { ok = true, reason = {
      transient_root = 'mem://transient',
      durable_root = 'mem://durable',
      durable_enabled = backing.durable_enabled,
    } }
  end)

  return backing
end

return M
