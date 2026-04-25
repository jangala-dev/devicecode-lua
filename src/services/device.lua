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
  return fibers.named_choice({
    cfg = shell_state.cfg_watch:recv_op(),
    obs = shell_state.obs_rx:recv_op(),
    work = shell_state.work_rx:recv_op(),
    self_req = shell_state.self_ep:recv_op(),
    list_req = shell_state.list_ep:recv_op(),
    get_req = shell_state.get_ep:recv_op(),
    do_req = shell_state.do_ep:recv_op(),
    changed = shell_state.changed:changed_op(shell_state.seen),
  })
end

local function publish_component(conn, svc, state, name)
  local rec = state.components[name]
  if not rec then return end
  local payloads = projection.component_payloads(name, rec, svc:now())
  conn:retain(projection.component_topic(name), payloads.component)
  conn:retain(projection.component_software_topic(name), payloads.software)
  conn:retain(projection.component_update_topic(name), payloads.update)
  model.clear_component_dirty(state, name)
end

local function publish_summary(conn, svc, state)
  local ts = svc:now()
  conn:retain(projection.summary_topic(), projection.summary_payload(state, ts))
  conn:retain(projection.self_topic(), projection.self_payload(state, ts))
  model.set_summary_clean(state)
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
    end
  end

  rebuild_observers(service_scope, conn, svc, state, obs_tx, observer_state)
  changed:signal()
end

local function handle_cfg_event(service_scope, conn, svc, state, changed, obs_tx, observer_state, ev, err)
  if not ev then
    svc:status('failed', { reason = tostring(err or 'cfg_watch_closed') })
    error('device cfg watch closed: ' .. tostring(err), 0)
  end
  if ev.op == 'retain' then
    apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_state, ev.payload)
  elseif ev.op == 'unretain' then
    apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_state, nil)
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
    conn:publish(projection.component_event_topic(ev.component, ev.event), ev.payload)
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
  local cap = cap_sdk.new_cap_ref(conn, 'artifact_store', artifact_store_id or 'main')
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

  local value, err = conn:call({ 'cmd', 'fabric', 'transfer' }, payload, { timeout = op.timeout_s or timeout })
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

local function handle_get_req(req, err, state, svc)
  if not req then error('device get endpoint closed: ' .. tostring(err), 0) end
  local payload = req.payload or {}
  local name = payload.component
  local rec = state.components[name]
  if type(name) ~= 'string' or not rec then
    req:fail('unknown_component')
    return
  end
  req:reply(projection.component_view(name, rec, svc:now()))
end

local function handle_do_req(work_tx, conn, req, err, state)
  if not req then error('device do endpoint closed: ' .. tostring(err), 0) end
  local payload = req.payload or {}
  local name = payload.component
  local action = payload.action
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
      return perform_component_action(conn, rec, action, payload.args or {}, payload.timeout)
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

  svc:status('starting')
  svc:spawn_heartbeat((opts.heartbeat_s or 30.0), 'tick')

  local state = model.new_state(SCHEMA)
  local changed = pulse.scoped({ close_reason = 'device service stopping' })
  local cfg_watch = conn:watch_retained({ 'cfg', 'device' }, { replay = true, queue_len = 8, full = 'drop_oldest' })
  local obs_tx, obs_rx = mailbox.new(128, { full = 'drop_oldest' })
  local work_tx, work_rx = mailbox.new(64, { full = 'reject_newest' })
  local observer_state = new_observer_state()

  local self_ep = conn:bind({ 'cmd', 'device', 'get' }, { queue_len = 32 })
  local list_ep = conn:bind({ 'cmd', 'device', 'component', 'list' }, { queue_len = 32 })
  local get_ep = conn:bind({ 'cmd', 'device', 'component', 'get' }, { queue_len = 32 })
  local do_ep = conn:bind({ 'cmd', 'device', 'component', 'do' }, { queue_len = 32 })

  local shell_state = {
    cfg_watch = cfg_watch,
    obs_rx = obs_rx,
    work_rx = work_rx,
    self_ep = self_ep,
    list_ep = list_ep,
    get_ep = get_ep,
    do_ep = do_ep,
    changed = changed,
    seen = changed:version(),
  }

  apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_state, nil)
  svc:status('running')

  fibers.current_scope():finally(function()
    close_observers(observer_state)
    cfg_watch:unwatch()
    self_ep:unbind()
    list_ep:unbind()
    get_ep:unbind()
    do_ep:unbind()
    for name in pairs(state.components) do
      conn:unretain(projection.component_topic(name))
      conn:unretain(projection.component_software_topic(name))
      conn:unretain(projection.component_update_topic(name))
    end
    conn:unretain(projection.self_topic())
    conn:unretain(projection.summary_topic())
  end)

  while true do
    local which, a, b = fibers.perform(next_device_event_op(shell_state))

    if which == 'cfg' then
      handle_cfg_event(service_scope, conn, svc, state, changed, obs_tx, observer_state, a, b)
    elseif which == 'obs' then
      handle_observer_event(conn, state, changed, observer_state, a)
    elseif which == 'work' then
      handle_work_event(a)
    elseif which == 'changed' then
      shell_state.seen = a or shell_state.seen
      publish_dirty(conn, svc, state)
    elseif which == 'self_req' then
      handle_self_req(a, b, state, svc)
    elseif which == 'list_req' then
      handle_list_req(a, b, state, svc)
    elseif which == 'get_req' then
      handle_get_req(a, b, state, svc)
    elseif which == 'do_req' then
      handle_do_req(work_tx, conn, a, b, state)
    end
  end
end

return M
