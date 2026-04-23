local checksum    = require 'services.fabric.checksum'
local blob_source = require 'services.fabric.blob_source'
local cjson       = require 'cjson.safe'

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

local function mk_mem_artifact(backing, rec)
  local art = {}
  function art:ref() return rec.artifact_ref end
  function art:meta() return clone(rec.meta) end
  function art:size() return rec.size end
  function art:checksum() return rec.checksum end
  function art:open_source() return blob_source.from_string(rec.data) end
  function art:delete() rec.deleted = true backing.artifacts[rec.artifact_ref] = nil return true end
  function art:describe()
    local out = clone(rec)
    out.data = nil
    out.deleted = nil
    return out
  end
  return art
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
      create_sink = true, import_path = true, import_source = true, open = true,
      delete = true, status = true,
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

  local create_sink_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'create_sink' }, { queue_len = 32 })
  local import_path_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'import_path' }, { queue_len = 32 })
  local import_source_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'import_source' }, { queue_len = 32 })
  local open_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'open' }, { queue_len = 32 })
  local delete_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'delete' }, { queue_len = 32 })
  local status_ep = conn:bind({ 'cap', 'artifact_store', 'main', 'rpc', 'status' }, { queue_len = 32 })

  local function store_blob(source, meta, policy)
    local durability, err = choose(policy)
    if not durability then return nil, err end
    local src, serr = blob_source.normalise_source(source)
    if not src then return nil, serr end
    local data = ''
    local offset = 0
    while true do
      local chunk, cerr = src:read_chunk(offset, 64 * 1024)
      if chunk == nil then return nil, cerr or 'read_failed' end
      if chunk == '' then break end
      data = data .. chunk
      offset = offset + #chunk
    end
    local ref = mkref()
    local rec = {
      artifact_ref = ref,
      state = 'ready',
      durability = durability,
      size = #data,
      checksum = checksum.digest_hex(data),
      meta = clone(meta or {}),
      data = data,
      created_at = os.time(),
      updated_at = os.time(),
    }
    backing.artifacts[ref] = rec
    return mk_mem_artifact(backing, rec), ''
  end

  bind_reply_loop(scope, create_sink_ep, function(payload)
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
    local sink = {
      write_chunk = function(_, offset, data)
        if type(data) ~= 'string' then return nil, 'invalid_chunk' end
        if offset ~= #rec.data then return nil, 'unexpected_offset' end
        rec.data = rec.data .. data
        rec.size = #rec.data
        rec.updated_at = os.time()
        return true
      end,
      size = function() return rec.size end,
      checksum = function() return checksum.digest_hex(rec.data) end,
      commit = function()
        rec.state = 'ready'
        rec.checksum = checksum.digest_hex(rec.data)
        rec.updated_at = os.time()
        backing.artifacts[ref] = rec
        return mk_mem_artifact(backing, rec), ''
      end,
      abort = function()
        backing.artifacts[ref] = nil
        return true
      end,
      status = function()
        return { artifact_ref = ref, state = rec.state, durability = rec.durability, size = rec.size }
      end,
    }
    return { ok = true, reason = sink }
  end)

  bind_reply_loop(scope, import_path_ep, function(payload)
    local data = backing.import_paths[payload.path]
    if type(data) ~= 'string' then return { ok = false, reason = 'not_found' } end
    local art, err = store_blob(blob_source.from_string(data), payload.meta, payload.policy)
    if not art then return { ok = false, reason = err } end
    return { ok = true, reason = art }
  end)

  bind_reply_loop(scope, import_source_ep, function(payload)
    local art, err = store_blob(payload.source, payload.meta, payload.policy)
    if not art then return { ok = false, reason = err } end
    return { ok = true, reason = art }
  end)

  bind_reply_loop(scope, open_ep, function(payload)
    local rec = backing.artifacts[payload.artifact_ref]
    if not rec or rec.deleted then return { ok = false, reason = 'not_found' } end
    return { ok = true, reason = mk_mem_artifact(backing, rec) }
  end)

  bind_reply_loop(scope, delete_ep, function(payload)
    local rec = backing.artifacts[payload.artifact_ref]
    if rec then rec.deleted = true end
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

function M.seed_import_path(backing, path, data)
  assert(type(backing) == 'table', 'backing required')
  assert(type(path) == 'string' and path ~= '', 'path required')
  assert(type(data) == 'string', 'data must be a string')
  backing.import_paths = backing.import_paths or {}
  backing.import_paths[path] = data
  return path
end

return M
