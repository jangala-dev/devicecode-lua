local fibers     = require 'fibers'
local pulse      = require 'fibers.pulse'
local mailbox    = require 'fibers.mailbox'
local base       = require 'devicecode.service_base'
local model      = require 'services.device.model'
local projection = require 'services.device.projection'
local observers  = require 'services.device.observers'
local cap_sdk    = require 'services.hal.sdk.cap'

local M = {}
local SCHEMA = 'devicecode.config/device/1'

local function send_required(tx, value, what)
  local ok, reason = tx:send(value)
  if ok ~= true then
    error((what or 'mailbox_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
  end
end

local function spawn_required(fn, what)
  local ok, err = fibers.spawn(fn)
  if ok ~= true then
    error((what or 'spawn_failed') .. ': ' .. tostring(err or 'spawn_failed'), 0)
  end
end

local function next_device_event_op(shell_state)
  local ops = {
    cfg = shell_state.cfg_watch:recv_op(),
    obs = shell_state.obs_rx:recv_op(),
    work = shell_state.work_rx:recv_op(),
    changed = shell_state.changed:changed_op(shell_state.seen),
  }
  for key, rec in pairs(shell_state.action_eps or {}) do
    ops[key] = rec.ep:recv_op()
  end
  return fibers.named_choice(ops)
end

local function publish_component(conn, svc, state, name)
  local rec = state.components[name]
  if not rec then return end
  local payloads = projection.component_payloads(name, rec, svc:now())
  conn:retain(projection.component_topic(name), payloads.component)
  conn:retain(projection.component_software_topic(name), payloads.software)
  conn:retain(projection.component_update_topic(name), payloads.update)
  conn:retain(projection.component_cap_meta_topic(name), {
    owner = svc.name,
    interface = 'devicecode.cap/component/1',
    component = name,
    methods = payloads.component.actions or {},
    events = { ['state-changed'] = true },
    canonical_state = projection.component_topic(name),
  })
  local cap_status = {
    state = payloads.component.available and 'available' or 'unavailable',
    health = payloads.component.health,
    ready = payloads.component.ready,
  }
  conn:retain(projection.component_cap_status_topic(name), cap_status)
  local should_emit_event = rec._published_once or payloads.component.available == true
  if should_emit_event then
    conn:publish(projection.component_cap_event_topic(name, 'state-changed'), {
      component = name,
      available = payloads.component.available,
      ready = payloads.component.ready,
      health = payloads.component.health,
      software = payloads.software,
      update = payloads.update,
      status = cap_status,
    })
  end
  rec._published_once = true
  model.clear_component_dirty(state, name)
end

local function publish_summary(conn, svc, state)
  local ts = svc:now()
  local summary = projection.summary_payload(state, ts)
  conn:retain(projection.summary_topic(), summary)
  conn:retain(projection.identity_topic(), projection.self_payload(state, ts))
  model.set_summary_clean(state)
  svc:set_ready(true, {
    components_total = summary.counts and summary.counts.total or 0,
    components_available = summary.counts and summary.counts.available or 0,
    components_degraded = summary.counts and summary.counts.degraded or 0,
  })
end

local function publish_dirty(conn, svc, state)
  for name in pairs(state.dirty_components) do
    publish_component(conn, svc, state, name)
  end
  if state.summary_dirty then
    publish_summary(conn, svc, state)
  end
end

local function new_observer_state()
  return { generation = 0, slots = {} }
end

local function close_observers(observer_state)
  local slots = observer_state.slots
  for _, slot in pairs(slots) do
    slot.scope:cancel('rebuild observers')
  end
  for _, slot in pairs(slots) do
    fibers.perform(slot.scope:join_op())
  end
  observer_state.slots = {}
end

local function rebuild_observers(service_scope, conn, svc, state, obs_tx, observer_state)
  close_observers(observer_state)
  observer_state.generation = observer_state.generation + 1
  local generation = observer_state.generation
  local next_slots = {}
  for name, rec in pairs(state.components) do
    local slot, err = observers.spawn_component(service_scope, conn, name, rec, obs_tx, generation)
    if slot then
      next_slots[name] = slot
    else
      svc:obs_log('warn', { what = 'observer_spawn_failed', component = name, err = tostring(err) })
    end
  end
  observer_state.slots = next_slots
end

local function apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_state, payload)
  local old = {}
  for name in pairs(state.components) do old[name] = true end

  model.apply_cfg(state, payload)

  for name in pairs(old) do
    if not state.components[name] then
      conn:unretain(projection.component_topic(name))
      conn:unretain(projection.component_software_topic(name))
      conn:unretain(projection.component_update_topic(name))
      conn:unretain(projection.component_cap_meta_topic(name))
      conn:unretain(projection.component_cap_status_topic(name))
    end
  end

  rebuild_observers(service_scope, conn, svc, state, obs_tx, observer_state)
  changed:signal()
end


local function sync_action_endpoints(conn, state, shell_state)
  local keep = {}
  for name, rec in pairs(state.components) do
    local methods = { ['get-status'] = true }
    for action_name in pairs(rec.operations or {}) do methods[action_name] = true end
    for method in pairs(methods) do
      local key = name .. ':' .. method
      keep[key] = true
      if not shell_state.action_eps[key] then
        shell_state.action_eps[key] = {
          component = name,
          action = method,
          ep = conn:bind(projection.component_cap_topic(name, method), { queue_len = 32 }),
        }
      end
    end
  end
  for key, rec in pairs(shell_state.action_eps) do
    if not keep[key] then
      rec.ep:unbind()
      shell_state.action_eps[key] = nil
    end
  end
end

local function handle_cfg_event(service_scope, conn, svc, state, changed, obs_tx, observer_state, shell_state, ev, err)
  if not ev then
    svc:failed(tostring(err or 'cfg_watch_closed'))
    error('device cfg watch closed: ' .. tostring(err), 0)
  end
  if ev.op == 'retain' then
    apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_state, ev.payload)
    sync_action_endpoints(conn, state, shell_state)
  elseif ev.op == 'unretain' then
    apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_state, nil)
    sync_action_endpoints(conn, state, shell_state)
  end
end

local function handle_observer_event(conn, state, changed, observer_state, ev)
  if not ev then return end
  local slot = observer_state.slots[ev.component]
  if not slot or ev.generation ~= slot.generation then return end

  if ev.tag == 'fact_changed' then
    model.note_fact(state, ev.component, ev.fact, ev.payload)
    changed:signal()
  elseif ev.tag == 'event_seen' then
    model.note_event(state, ev.component, ev.event, ev.payload)
    changed:signal()
  elseif ev.tag == 'source_down' then
    model.note_source_down(state, ev.component, ev.reason)
    changed:signal()
  end
end

local function spawn_work_helper(work_tx, spec)
  spawn_required(function()
    local st, _report, value, err = fibers.run_scope(spec.run)

    if st == 'cancelled' then return end
    if st == 'failed' then
      send_required(work_tx, {
        tag = spec.done_tag,
        req = spec.req,
        component = spec.component,
        ok = false,
        err = tostring(value or 'helper_failed'),
      }, spec.overflow_what)
      return
    end
    if value == nil then
      send_required(work_tx, {
        tag = spec.done_tag,
        req = spec.req,
        component = spec.component,
        ok = false,
        err = err,
      }, spec.overflow_what)
      return
    end
    send_required(work_tx, {
      tag = spec.done_tag,
      req = spec.req,
      component = spec.component,
      ok = true,
      value = value,
    }, spec.overflow_what)
  end, spec.spawn_what)
end

local function open_artifact(conn, artifact_store_id, artifact_ref)
  if type(artifact_ref) ~= 'string' or artifact_ref == '' then
    return nil, 'missing_artifact_ref'
  end
  local cap = cap_sdk.new_raw_host_cap_ref(conn, 'artifact-store', 'artifact-store', artifact_store_id or 'main')
  local opts_ = assert(cap_sdk.args.new.ArtifactStoreOpenOpts(artifact_ref))
  local reply, err = cap:call_control('open', opts_)
  if not reply then return nil, err end
  if reply.ok ~= true then return nil, reply.reason end
  return reply.reason, nil
end

local function perform_fabric_stage(conn, rec, action_name, args, timeout)
  local op = rec.operations and rec.operations[action_name] or nil
  if not op then return nil, 'unknown_action' end

  args = type(args) == 'table' and args or {}
  local artifact, aerr = open_artifact(conn, op.artifact_store, args.artifact_ref)
  if not artifact then return nil, aerr or 'artifact_open_failed' end

  local desc = type(artifact.describe) == 'function' and artifact:describe() or nil
  local meta = type(args.metadata) == 'table' and model.copy_value(args.metadata) or nil
  local payload = {
    op = 'send_blob',
    link_id = op.link_id,
    receiver = model.copy_array(op.receiver),
    source = artifact,
    meta = {
      kind = 'firmware',
      component = rec.name,
      image_id = args.expected_image_id,
      job_id = args.job_id,
      size = (type(desc) == 'table' and desc.size) or (type(artifact.size) == 'function' and artifact:size() or nil),
      checksum = (type(desc) == 'table' and desc.checksum) or (type(artifact.checksum) == 'function' and artifact:checksum() or nil),
      metadata = meta,
    },
  }

  local value, err = conn:call({ 'cap', 'transfer-manager', 'main', 'rpc', 'send-blob' }, payload, { timeout = op.timeout_s or timeout })
  if value == nil then return nil, err end
  if type(value) ~= 'table' then value = { ok = true } end
  if value.artifact_retention == nil then value.artifact_retention = 'release' end
  value.staged = true
  return value, nil
end

local function perform_rpc_action(conn, rec, action_name, args, timeout)
  local route = rec.operations and rec.operations[action_name] or nil
  if not route or type(route.call_topic) ~= 'table' then
    return nil, 'unsupported_action'
  end
  return conn:call(route.call_topic, args or {}, { timeout = timeout })
end

local function perform_component_action(conn, rec, action, args, timeout)
  local op = rec.operations and rec.operations[action] or nil
  if not op then return nil, 'unknown_action' end
  if op.kind == 'fabric_stage' then
    return perform_fabric_stage(conn, rec, action, args, timeout)
  end
  return perform_rpc_action(conn, rec, action, args, timeout)
end

local function handle_self_req(req, err, state, svc)
  if not req then error('device self endpoint closed: ' .. tostring(err), 0) end
  req:reply({ ok = true, device = projection.self_payload(state, svc:now()) })
end

local function handle_list_req(req, err, state, svc)
  if not req then error('device list endpoint closed: ' .. tostring(err), 0) end
  local items = {}
  for name, rec in pairs(state.components) do
    items[#items + 1] = projection.component_view(name, rec, svc:now())
  end
  table.sort(items, function(x, y) return tostring(x.component) < tostring(y.component) end)
  req:reply({ ok = true, components = items })
end

local function handle_get_req(req, err, state, svc, forced_component)
  if not req then error('device get endpoint closed: ' .. tostring(err), 0) end
  local payload = req.payload or {}
  local name = forced_component or payload.component
  local rec = state.components[name]
  if type(name) ~= 'string' or not rec then
    req:fail('unknown_component')
    return
  end
  req:reply(projection.component_view(name, rec, svc:now()))
end

local function handle_action_req(work_tx, conn, req, err, state, component, action)
  if not req then error('device do endpoint closed: ' .. tostring(err), 0) end
  local payload = req.payload or {}
  local name = component or payload.component
  action = action or payload.action
  local rec = state.components[name]
  if type(name) ~= 'string' or not rec then
    req:fail('unknown_component')
    return
  end
  spawn_work_helper(work_tx, {
    done_tag = 'do_done',
    req = req,
    component = name,
    spawn_what = 'device_do_helper_spawn',
    overflow_what = 'device_do_done_overflow',
    run = function()
      local call_args = payload.args or payload or {}
      return perform_component_action(conn, rec, action, call_args, payload.timeout)
    end,
  })
end

local function handle_work_event(ev)
  if not ev then error('device work mailbox closed', 0) end
  if ev.tag == 'do_done' then
    local req = ev.req
    if not req or req:done() then return end
    if not ev.ok then req:fail(ev.err) else req:reply(ev.value) end
  end
end

function M.start(conn, opts)
  opts = opts or {}

  local service_scope = assert(fibers.current_scope())
  local svc = base.new(conn, { name = opts.name or 'device', env = opts.env })

  svc:announce({
    role = 'device',
    caps = {
      component = true,
    },
  })

  svc:starting({ components_total = 0, components_available = 0, components_degraded = 0 })
  svc:spawn_heartbeat((opts.heartbeat_s or 30.0), 'tick')

  local state = model.new_state(SCHEMA)
  local changed = pulse.scoped({ close_reason = 'device service stopping' })
  local cfg_watch = conn:watch_retained({ 'cfg', 'device' }, { replay = true, queue_len = 8, full = 'drop_oldest' })
  local obs_tx, obs_rx = mailbox.new(128, { full = 'drop_oldest' })
  local work_tx, work_rx = mailbox.new(64, { full = 'reject_newest' })
  local observer_state = new_observer_state()

  local shell_state = {
    cfg_watch = cfg_watch,
    obs_rx = obs_rx,
    work_rx = work_rx,
    action_eps = {},
    changed = changed,
    seen = changed:version(),
  }

  apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_state, nil)
  sync_action_endpoints(conn, state, shell_state)
  svc:running({
    components_total = 0,
    components_available = 0,
    components_degraded = 0,
  })
  publish_dirty(conn, svc, state)

  fibers.current_scope():finally(function()
    close_observers(observer_state)
    cfg_watch:unwatch()
    for _, rec in pairs(shell_state.action_eps) do rec.ep:unbind() end
    for name in pairs(state.components) do
      conn:unretain(projection.component_topic(name))
      conn:unretain(projection.component_software_topic(name))
      conn:unretain(projection.component_update_topic(name))
      conn:unretain(projection.component_cap_meta_topic(name))
      conn:unretain(projection.component_cap_status_topic(name))
    end
    conn:unretain(projection.identity_topic())
    conn:unretain(projection.summary_topic())
  end)

  while true do
    local which, a, b = fibers.perform(next_device_event_op(shell_state))

    if which == 'cfg' then
      handle_cfg_event(service_scope, conn, svc, state, changed, obs_tx, observer_state, shell_state, a, b)
    elseif which == 'obs' then
      handle_observer_event(conn, state, changed, observer_state, a)
    elseif which == 'work' then
      handle_work_event(a)
    elseif which == 'changed' then
      shell_state.seen = a or shell_state.seen
      publish_dirty(conn, svc, state)
    elseif type(which) == 'string' and shell_state.action_eps[which] then
      local rec = shell_state.action_eps[which]
      if rec.action == 'get-status' then
        handle_get_req(a, b, state, svc, rec.component)
      else
        handle_action_req(work_tx, conn, a, b, state, rec.component, rec.action)
      end
    end
  end
end

return M
