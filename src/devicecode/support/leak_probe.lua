-- devicecode/support/leak_probe.lua
--
-- Opt-in leak instrumentation for VM testing.
-- Enable with DEVICECODE_LEAK_PROBE=1.
-- Optional:
--   DEVICECODE_LEAK_PROBE_INTERVAL=60
--   DEVICECODE_LEAK_PROBE_FILE=/tmp/devicecode-leak-probe.log
--   DEVICECODE_LEAK_PROBE_TOP=12
--   DEVICECODE_LEAK_PROBE_BUS=1
--
-- The module deliberately stores identifiers and small strings only.  It should
-- not retain service objects, scopes, commands, requests, streams or payloads.

local M = {}

local function getenv(name)
  if os and os.getenv then return os.getenv(name) end
end

local function truthy(v)
  if v == nil or v == '' then return false end
  v = tostring(v):lower()
  return not (v == '0' or v == 'false' or v == 'no' or v == 'off')
end

local enabled = truthy(getenv('DEVICECODE_LEAK_PROBE'))
local interval = tonumber(getenv('DEVICECODE_LEAK_PROBE_INTERVAL') or '') or 60
if interval <= 0 then interval = 60 end
local top_n = tonumber(getenv('DEVICECODE_LEAK_PROBE_TOP') or '') or 10
if top_n < 1 then top_n = 1 end

local state = {
  enabled = enabled,
  started = false,
  counters = {},
  gauges = {},
  notes = {},
  scopes = {
    live = 0,
    created = 0,
    records = {}, -- id -> small record only
  },
  exec = {
    next_id = 0,
    live = {}, -- id -> small record only
  },
  bus = {
    next_id = 0,
    buses = {},
    retained = {}, -- topic key -> true
  },
  mailboxes = {
    next_id = 0,
    live = {},
  },
  scoped_work = {
    next_id = 0,
    live = {},
  },
  request_owner = {
    next_id = 0,
    live = {},
  },
  ingest = {
    instances = {},
  },
}

local function now()
  local ok, fibers = pcall(require, 'fibers')
  if ok and fibers and type(fibers.now) == 'function' then
    local ok_now, t = pcall(fibers.now)
    if ok_now and type(t) == 'number' then return t end
  end
  return os.time()
end

local function bump(tbl, key, delta)
  tbl[key] = (tbl[key] or 0) + (delta or 1)
end

function M.enabled()
  return enabled
end

function M.bump(name, delta)
  if not enabled then return end
  bump(state.counters, name, delta or 1)
end

function M.gauge(name, value)
  if not enabled then return end
  state.gauges[name] = value
end

function M.note(name, value)
  if not enabled then return end
  state.notes[name] = tostring(value)
end

local function string_limit(v, max)
  v = tostring(v == nil and '' or v)
  max = max or 96
  if #v > max then return v:sub(1, max - 3) .. '...' end
  return v
end

local function argv_label(argv)
  if type(argv) ~= 'table' then return '' end
  local parts = {}
  for i = 1, math.min(#argv, 6) do parts[#parts + 1] = tostring(argv[i]) end
  local s = table.concat(parts, ' ')
  if #argv > 6 then s = s .. ' ...' end
  return string_limit(s, 160)
end

-- Scope instrumentation -------------------------------------------------------
function M.scope_created(id, parent_id)
  if not enabled then return end
  state.scopes.created = state.scopes.created + 1
  state.scopes.live = state.scopes.live + 1
  state.scopes.records[id] = {
    id = id,
    parent = parent_id,
    children = 0,
    finalizers = 0,
    spawned = 0,
    cancelled = false,
    closed = false,
    join_started = false,
    joined = false,
    created_at = now(),
  }
  if parent_id and state.scopes.records[parent_id] then
    local p = state.scopes.records[parent_id]
    p.children = (p.children or 0) + 1
  end
  M.bump('scope.created')
end

function M.scope_child_detached(parent_id, child_id)
  if not enabled then return end
  local p = parent_id and state.scopes.records[parent_id]
  if p then p.children = math.max(0, (p.children or 0) - 1) end
  local ch = child_id and state.scopes.records[child_id]
  if ch then ch.parent = nil; ch.detached = true end
  M.bump('scope.child_detached')
end

function M.scope_closed(id, reason)
  if not enabled then return end
  local r = state.scopes.records[id]
  if r then r.closed = true; r.close_reason = string_limit(reason, 80) end
  M.bump('scope.closed')
end

function M.scope_cancelled(id, reason)
  if not enabled then return end
  local r = state.scopes.records[id]
  if r then r.cancelled = true; r.cancel_reason = string_limit(reason, 80) end
  M.bump('scope.cancelled')
end

function M.scope_spawned(id)
  if not enabled then return end
  local r = state.scopes.records[id]
  if r then r.spawned = (r.spawned or 0) + 1 end
  M.bump('scope.spawned')
end

function M.scope_finalizer_added(id)
  if not enabled then return end
  local r = state.scopes.records[id]
  if r then r.finalizers = (r.finalizers or 0) + 1 end
  M.bump('scope.finalizer_added')
end

function M.scope_finalizer_removed(id, why)
  if not enabled then return end
  local r = state.scopes.records[id]
  if r then r.finalizers = math.max(0, (r.finalizers or 0) - 1) end
  M.bump('scope.finalizer_removed')
  if why then M.bump('scope.finalizer_removed.' .. tostring(why)) end
end

function M.scope_join_started(id)
  if not enabled then return end
  local r = state.scopes.records[id]
  if r then r.join_started = true end
  M.bump('scope.join_started')
end

function M.scope_join_done(id, status)
  if not enabled then return end
  local r = state.scopes.records[id]
  if r and not r.joined then
    r.joined = true
    r.status = status
    state.scopes.live = math.max(0, state.scopes.live - 1)
    state.scopes.records[id] = nil
  end
  M.bump('scope.join_done')
  if status then M.bump('scope.join_done.' .. tostring(status)) end
end

-- Exec instrumentation --------------------------------------------------------
function M.exec_next_id()
  if not enabled then return nil end
  state.exec.next_id = state.exec.next_id + 1
  return state.exec.next_id
end

function M.exec_created(id, scope_id, argv)
  if not (enabled and id) then return end
  state.exec.live[id] = {
    id = id,
    scope = scope_id,
    argv = argv_label(argv),
    created_at = now(),
    started = false,
    terminal = false,
    cleaned = false,
  }
  M.bump('exec.created')
end

function M.exec_started(id, pid)
  if not (enabled and id) then return end
  local r = state.exec.live[id]
  if r then r.started = true; r.pid = pid end
  M.bump('exec.started')
end

function M.exec_exit(id, status, code, signal, err)
  if not (enabled and id) then return end
  local r = state.exec.live[id]
  if r then
    r.terminal = true
    r.status = status
    r.code = code
    r.signal = signal
    r.err = string_limit(err, 120)
  end
  M.bump('exec.terminal')
  if status then M.bump('exec.terminal.' .. tostring(status)) end
end

function M.exec_scope_exit(id)
  if not (enabled and id) then return end
  M.bump('exec.scope_exit_cleanup')
end

function M.exec_cleaned(id, why)
  if not (enabled and id) then return end
  local r = state.exec.live[id]
  if r then r.cleaned = true; state.exec.live[id] = nil end
  M.bump('exec.cleaned')
  if why then M.bump('exec.cleaned.' .. tostring(why)) end
end

-- Bus instrumentation ---------------------------------------------------------
function M.bus_next_id()
  if not enabled then return nil end
  state.bus.next_id = state.bus.next_id + 1
  return state.bus.next_id
end

function M.bus_created(id)
  if not (enabled and id) then return end
  state.bus.buses[id] = { connections = 0, retained = 0 }
  M.bump('bus.created')
end

function M.bus_connection_created(bus_id)
  if not enabled then return end
  local b = bus_id and state.bus.buses[bus_id]
  if b then b.connections = (b.connections or 0) + 1 end
  M.bump('bus.connection.created')
end

function M.bus_connection_closed(bus_id)
  if not enabled then return end
  local b = bus_id and state.bus.buses[bus_id]
  if b then b.connections = math.max(0, (b.connections or 0) - 1) end
  M.bump('bus.connection.closed')
end

function M.bus_feed_created(kind)
  if not enabled then return end
  M.bump('bus.' .. tostring(kind) .. '.created')
  bump(state.gauges, 'bus.' .. tostring(kind) .. '.live', 1)
end

function M.bus_feed_closed(kind)
  if not enabled then return end
  M.bump('bus.' .. tostring(kind) .. '.closed')
  local k = 'bus.' .. tostring(kind) .. '.live'
  state.gauges[k] = math.max(0, (state.gauges[k] or 0) - 1)
end

function M.bus_retained(bus_id, key, topic)
  if not enabled then return end
  local k = tostring(bus_id or '?') .. ':' .. tostring(key)
  if not state.bus.retained[k] then
    state.bus.retained[k] = topic or true
    local b = bus_id and state.bus.buses[bus_id]
    if b then b.retained = (b.retained or 0) + 1 end
    M.bump('bus.retained.new')
  end
  M.bump('bus.retain')
end

function M.bus_unretained(bus_id, key)
  if not enabled then return end
  local k = tostring(bus_id or '?') .. ':' .. tostring(key)
  if state.bus.retained[k] then
    state.bus.retained[k] = nil
    local b = bus_id and state.bus.buses[bus_id]
    if b then b.retained = math.max(0, (b.retained or 0) - 1) end
    M.bump('bus.retained.removed')
  end
  M.bump('bus.unretain')
end

function M.bus_call_started() if enabled then M.bump('bus.call.started') end end
function M.bus_call_resolved(kind)
  if enabled then M.bump('bus.call.resolved'); if kind then M.bump('bus.call.resolved.' .. tostring(kind)) end end
end

-- Mailbox instrumentation -----------------------------------------------------
function M.mailbox_next_id()
  if not enabled then return nil end
  state.mailboxes.next_id = state.mailboxes.next_id + 1
  return state.mailboxes.next_id
end

function M.mailbox_created(id, cap, full)
  if not (enabled and id) then return end
  state.mailboxes.live[id] = { id = id, cap = cap or 0, full = tostring(full), senders = 1, closed = false, dropped = 0 }
  M.bump('mailbox.created')
  M.bump('mailbox.created.' .. tostring(full))
end

function M.mailbox_sender_cloned(id)
  if not (enabled and id) then return end
  local r = state.mailboxes.live[id]
  if r then r.senders = (r.senders or 0) + 1 end
  M.bump('mailbox.sender_cloned')
end

function M.mailbox_sender_closed(id)
  if not (enabled and id) then return end
  local r = state.mailboxes.live[id]
  if r then r.senders = math.max(0, (r.senders or 0) - 1) end
  M.bump('mailbox.sender_closed')
end

function M.mailbox_closed(id, reason)
  if not (enabled and id) then return end
  local r = state.mailboxes.live[id]
  if r then
    r.closed = true
    r.reason = string_limit(reason, 80)
    state.mailboxes.live[id] = nil
  end
  M.bump('mailbox.closed')
end

function M.mailbox_dropped(id, full)
  if not enabled then return end
  local r = id and state.mailboxes.live[id]
  if r then r.dropped = (r.dropped or 0) + 1 end
  M.bump('mailbox.dropped')
  if full then M.bump('mailbox.dropped.' .. tostring(full)) end
end

-- devicecode support instrumentation -----------------------------------------
function M.scoped_work_started(identity)
  if not enabled then return nil end
  state.scoped_work.next_id = state.scoped_work.next_id + 1
  local id = state.scoped_work.next_id
  state.scoped_work.live[id] = {
    id = id,
    kind = identity and identity.kind or nil,
    generation = identity and identity.generation or nil,
    service_id = identity and identity.service_id or nil,
    request_id = identity and identity.request_id or nil,
    created_at = now(),
  }
  M.bump('scoped_work.started')
  if identity and identity.kind then M.bump('scoped_work.started.' .. tostring(identity.kind)) end
  return id
end

function M.scoped_work_body_done(id)
  if not (enabled and id) then return end
  local r = state.scoped_work.live[id]
  if r then r.body_done = true end
  M.bump('scoped_work.body_done')
end

function M.scoped_work_reaped(id, status)
  if not (enabled and id) then return end
  local r = state.scoped_work.live[id]
  if r then r.reaped = true; r.status = status end
  M.bump('scoped_work.reaped')
  if status then M.bump('scoped_work.reaped.' .. tostring(status)) end
end

function M.scoped_work_reported(id)
  if not (enabled and id) then return end
  state.scoped_work.live[id] = nil
  M.bump('scoped_work.reported')
end

function M.scoped_work_cancelled(id, reason)
  if not (enabled and id) then return end
  local r = state.scoped_work.live[id]
  if r then r.cancel_reason = string_limit(reason, 80) end
  M.bump('scoped_work.cancelled')
end

function M.request_owner_created()
  if not enabled then return nil end
  state.request_owner.next_id = state.request_owner.next_id + 1
  local id = state.request_owner.next_id
  state.request_owner.live[id] = { id = id, created_at = now(), done = false }
  M.bump('request_owner.created')
  return id
end

function M.request_owner_resolved(id, kind)
  if not (enabled and id) then return end
  state.request_owner.live[id] = nil
  M.bump('request_owner.resolved')
  if kind then M.bump('request_owner.resolved.' .. tostring(kind)) end
end

function M.ingest_instance_created(id)
  if not enabled then return end
  state.ingest.instances[tostring(id)] = { id = tostring(id), created_at = now(), closed = false }
  M.bump('ingest.instance.created')
end

function M.ingest_instance_closed(id, reason)
  if not enabled then return end
  local r = state.ingest.instances[tostring(id)]
  if r then r.closed = true; r.reason = string_limit(reason, 80) end
  M.bump('ingest.instance.closed')
end

function M.ingest_instance_removed(id)
  if not enabled then return end
  state.ingest.instances[tostring(id)] = nil
  M.bump('ingest.instance.removed')
end

-- Snapshot/reporting ----------------------------------------------------------
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function append_kv(parts, k, v)
  parts[#parts + 1] = tostring(k) .. '=' .. tostring(v)
end

local function count_table(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function top_records(records, field, n)
  local rows = {}
  for _, r in pairs(records or {}) do
    if (r[field] or 0) > 0 then rows[#rows + 1] = r end
  end
  table.sort(rows, function(a, b) return (a[field] or 0) > (b[field] or 0) end)
  local out = {}
  for i = 1, math.min(n or top_n, #rows) do
    local r = rows[i]
    out[#out + 1] = ('id:%s.%s:%s.parent:%s.children:%s.join:%s.cancel:%s'):format(
      tostring(r.id), tostring(field), tostring(r[field] or 0), tostring(r.parent), tostring(r.children or 0), tostring(r.join_started), tostring(r.cancelled))
  end
  return table.concat(out, ',')
end

local function exec_summary()
  local live, terminal_not_cleaned, running, pending = 0, 0, 0, 0
  local samples = {}
  for _, r in pairs(state.exec.live) do
    live = live + 1
    if r.terminal and not r.cleaned then terminal_not_cleaned = terminal_not_cleaned + 1 end
    if r.started and not r.terminal then running = running + 1 end
    if not r.started then pending = pending + 1 end
    if #samples < top_n then
      samples[#samples + 1] = ('id:%s.scope:%s.term:%s.argv:%s'):format(tostring(r.id), tostring(r.scope), tostring(r.terminal), tostring(r.argv))
    end
  end
  return live, terminal_not_cleaned, running, pending, table.concat(samples, ' | ')
end

local function scoped_work_summary()
  local live, reaped_not_reported, body_not_reaped = 0, 0, 0
  local by_kind = {}
  for _, r in pairs(state.scoped_work.live) do
    live = live + 1
    if r.reaped then reaped_not_reported = reaped_not_reported + 1 end
    if r.body_done and not r.reaped then body_not_reaped = body_not_reaped + 1 end
    by_kind[tostring(r.kind or '?')] = (by_kind[tostring(r.kind or '?')] or 0) + 1
  end
  local kinds = {}
  for _, k in ipairs(sorted_keys(by_kind)) do kinds[#kinds + 1] = k .. ':' .. by_kind[k] end
  return live, reaped_not_reported, body_not_reaped, table.concat(kinds, ',')
end

local function scope_summary()
  local finalizers, cancelled, joining, children, closed = 0, 0, 0, 0, 0
  for _, r in pairs(state.scopes.records) do
    finalizers = finalizers + (r.finalizers or 0)
    children = children + (r.children or 0)
    if r.cancelled then cancelled = cancelled + 1 end
    if r.closed then closed = closed + 1 end
    if r.join_started and not r.joined then joining = joining + 1 end
  end
  return finalizers, children, cancelled, closed, joining
end

local function mailbox_summary()
  local live, closed, senders, dropped = 0, 0, 0, 0
  for _, r in pairs(state.mailboxes.live) do
    live = live + 1
    if r.closed then closed = closed + 1 end
    senders = senders + (r.senders or 0)
    dropped = dropped + (r.dropped or 0)
  end
  return live, closed, senders, dropped
end

local function bus_summary()
  local buses, conns, retained = 0, 0, 0
  for _, b in pairs(state.bus.buses) do
    buses = buses + 1
    conns = conns + (b.connections or 0)
    retained = retained + (b.retained or 0)
  end
  return buses, conns, retained
end

local function ingest_summary()
  local live, closed = 0, 0
  for _, r in pairs(state.ingest.instances) do
    live = live + 1
    if r.closed then closed = closed + 1 end
  end
  return live, closed
end

function M.snapshot()
  local parts = {}
  append_kv(parts, 't', now())
  append_kv(parts, 'mem_kb', string.format('%.1f', collectgarbage('count')))

  local scope_finalizers, scope_children, scope_cancelled, scope_closed, scope_joining = scope_summary()
  append_kv(parts, 'scope_live', state.scopes.live)
  append_kv(parts, 'scope_records', count_table(state.scopes.records))
  append_kv(parts, 'scope_children', scope_children)
  append_kv(parts, 'scope_finalizers', scope_finalizers)
  append_kv(parts, 'scope_cancelled', scope_cancelled)
  append_kv(parts, 'scope_closed', scope_closed)
  append_kv(parts, 'scope_joining', scope_joining)

  local exec_live, exec_terminal_not_cleaned, exec_running, exec_pending, exec_samples = exec_summary()
  append_kv(parts, 'exec_live', exec_live)
  append_kv(parts, 'exec_terminal_not_cleaned', exec_terminal_not_cleaned)
  append_kv(parts, 'exec_running', exec_running)
  append_kv(parts, 'exec_pending', exec_pending)

  local mb_live, mb_closed, mb_senders, mb_dropped = mailbox_summary()
  append_kv(parts, 'mailbox_live', mb_live)
  append_kv(parts, 'mailbox_closed', mb_closed)
  append_kv(parts, 'mailbox_senders', mb_senders)
  append_kv(parts, 'mailbox_dropped', mb_dropped)

  local bus_count, bus_conns, bus_retained = bus_summary()
  append_kv(parts, 'bus_count', bus_count)
  append_kv(parts, 'bus_connections', bus_conns)
  append_kv(parts, 'bus_retained', bus_retained)

  local sw_live, sw_reaped, sw_body_not_reaped, sw_kinds = scoped_work_summary()
  append_kv(parts, 'scoped_work_live', sw_live)
  append_kv(parts, 'scoped_work_reaped_not_reported', sw_reaped)
  append_kv(parts, 'scoped_work_body_not_reaped', sw_body_not_reaped)

  append_kv(parts, 'request_owner_live', count_table(state.request_owner.live))
  local ingest_live, ingest_closed = ingest_summary()
  append_kv(parts, 'ingest_instances_tracked', ingest_live)
  append_kv(parts, 'ingest_instances_closed', ingest_closed)

  for _, k in ipairs(sorted_keys(state.gauges)) do
    append_kv(parts, 'g.' .. k, state.gauges[k])
  end
  for _, k in ipairs(sorted_keys(state.counters)) do
    append_kv(parts, 'c.' .. k, state.counters[k])
  end

  local line = 'LEAK_PROBE ' .. table.concat(parts, ' ')
  local details = {
    line,
    'LEAK_PROBE_TOP_SCOPES ' .. top_records(state.scopes.records, 'finalizers', top_n),
    'LEAK_PROBE_EXEC_SAMPLES ' .. exec_samples,
    'LEAK_PROBE_SCOPED_WORK_KINDS ' .. sw_kinds,
  }
  return details
end

local function write_lines(lines)
  local path = getenv('DEVICECODE_LEAK_PROBE_FILE')
  if path and path ~= '' then
    local f = io.open(path, 'a')
    if f then
      for i = 1, #lines do f:write(lines[i], '\n') end
      f:close()
      return
    end
  end
  for i = 1, #lines do print(lines[i]) end
end

function M.report()
  if not enabled then return end
  collectgarbage('collect')
  write_lines(M.snapshot())
end

function M.start(scope, opts)
  if not enabled or state.started then return false end
  state.started = true
  opts = opts or {}

  if opts.note then M.note('note', opts.note) end
  M.report()

  local ok_fibers, fibers = pcall(require, 'fibers')
  local ok_sleep, sleep = pcall(require, 'fibers.sleep')
  if not (ok_fibers and ok_sleep and scope and type(scope.spawn) == 'function') then
    return true
  end

  scope:spawn(function()
    while true do
      fibers.perform(sleep.sleep_op(interval))
      M.report()
      if truthy(getenv('DEVICECODE_LEAK_PROBE_BUS')) and opts.conn and type(opts.conn.retain) == 'function' then
        local snap = M.snapshot()[1]
        pcall(function () opts.conn:retain({ 'obs', 'v1', 'leak_probe', 'snapshot' }, { line = snap, t = now() }) end)
      end
    end
  end)

  return true
end

return M
