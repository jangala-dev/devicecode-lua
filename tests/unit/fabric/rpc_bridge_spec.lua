local fibers     = require 'fibers'
local mailbox    = require 'fibers.mailbox'
local pulse_mod  = require 'fibers.pulse'
local sleep      = require 'fibers.sleep'
local op         = require 'fibers.op'

local rpc_bridge = require 'services.fabric.rpc_bridge'
local topics     = require 'services.fabric.topics'

local runfibers  = require 'tests.support.run_fibers'

local T = {}

local function topic_key(topic)
  local parts = {}
  for i = 1, #topic do
    parts[#parts + 1] = tostring(topic[i])
  end
  return table.concat(parts, '/')
end

local function copy_topic(topic)
  local out = {}
  for i = 1, #topic do out[i] = topic[i] end
  return out
end

local function topics_equal(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' or #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function topic_matches(pattern, topic)
  if type(pattern) ~= 'table' or type(topic) ~= 'table' then return false end
  local n = #pattern
  if n > 0 and pattern[n] == '#' then
    if #topic < (n - 1) then return false end
    for i = 1, n - 1 do
      if pattern[i] ~= topic[i] then return false end
    end
    return true
  end
  return topics_equal(pattern, topic)
end

local function shallow_copy(t)
  local out = {}
  if t then
    for k, v in pairs(t) do out[k] = v end
  end
  return out
end

local function make_watchable(initial)
  local pulse = pulse_mod.new()
  local snap = shallow_copy(initial)
  local holder = {}

  function holder:snapshot()
    return shallow_copy(snap)
  end

  function holder:version()
    return pulse:version()
  end

  function holder:changed_op(seen)
    return pulse:changed_op(seen):wrap(function(version, reason)
      if version == nil then return nil, reason end
      return version, self:snapshot()
    end)
  end

  function holder:set_snapshot(next_)
    local changed = false
    for k, v in pairs(next_) do
      if snap[k] ~= v then
        changed = true
        break
      end
    end
    if not changed then
      for k in pairs(snap) do
        if next_[k] == nil then
          changed = true
          break
        end
      end
    end
    if changed then
      snap = shallow_copy(next_)
      pulse:signal()
      return true
    end
    return false
  end

  return holder
end

local function new_state_conn()
  local conn = {
    retains = {},
    retain_history = {},
    unretains = {},
  }

  function conn:retain(topic, payload)
    local k = topic_key(topic)
    self.retains[k] = { topic = copy_topic(topic), payload = payload }
    self.retain_history[#self.retain_history + 1] = { topic = copy_topic(topic), payload = payload }
    return true
  end

  function conn:unretain(topic)
    local k = topic_key(topic)
    self.unretains[k] = true
    self.retains[k] = nil
    return true
  end

  return conn
end

local function recv_now(rx)
  return fibers.perform(rx:recv_op():or_else(function()
    return nil
  end))
end

local function wait_until(pred, timeout_s)
  local deadline = fibers.now() + (timeout_s or 0.5)
  while fibers.now() < deadline do
    if pred() then return true end
    sleep.sleep(0.01)
  end
  error(('timed out after %.3fs'):format(timeout_s or 0.5), 0)
end

local function new_req(topic, payload)
  return {
    topic = copy_topic(topic),
    payload = payload,
    replied = false,
    failed = false,
    result = nil,
    err = nil,

    reply = function(self, result)
      self.replied = true
      self.result = result
    end,

    fail = function(self, err)
      self.failed = true
      self.err = err
    end,
  }
end

local function new_fake_conn()
  local conn = {
    published = {},
    retained = {},
    unretained = {},
    subscriptions = {},
    watches = {},
    bound = {},
    call_handlers = {},
  }

  local function deliver_sub(topic, payload)
    for _, rec in ipairs(conn.subscriptions) do
      if rec.active and topic_matches(rec.topic, topic) then
        rec.tx:send({ topic = copy_topic(topic), payload = payload })
      end
    end
  end

  local function deliver_watch_retain(topic, payload)
    for _, rec in ipairs(conn.watches) do
      if rec.active and topic_matches(rec.topic, topic) then
        rec.tx:send({
          op = 'retain',
          topic = copy_topic(topic),
          payload = payload,
        })
      end
    end
  end

  local function deliver_watch_unretain(topic)
    for _, rec in ipairs(conn.watches) do
      if rec.active and topic_matches(rec.topic, topic) then
        rec.tx:send({
          op = 'unretain',
          topic = copy_topic(topic),
        })
      end
    end
  end

  function conn:publish(topic, payload)
    self.published[#self.published + 1] = { topic = copy_topic(topic), payload = payload }
    deliver_sub(topic, payload)
    return true
  end

  function conn:retain(topic, payload)
    self.retained[topic_key(topic)] = { topic = copy_topic(topic), payload = payload }
    deliver_sub(topic, payload)
    deliver_watch_retain(topic, payload)
    return true
  end

  function conn:unretain(topic)
    self.unretained[topic_key(topic)] = true
    self.retained[topic_key(topic)] = nil
    deliver_watch_unretain(topic)
    return true
  end

  function conn:subscribe(topic, opts)
    local tx, rx = mailbox.new((opts and opts.queue_len) or 16, { full = 'reject_newest' })
    local rec = { topic = copy_topic(topic), tx = tx, rx = rx, active = true }
    self.subscriptions[#self.subscriptions + 1] = rec

    return {
      recv_op = function()
        return rx:recv_op()
      end,
      unsubscribe = function()
        rec.active = false
        tx:close('unsubscribed')
        return true
      end,
      _tx = tx,
      _rx = rx,
    }
  end

  function conn:watch_retained(topic, opts)
    local tx, rx = mailbox.new((opts and opts.queue_len) or 16, { full = 'reject_newest' })
    local rec = { topic = copy_topic(topic), tx = tx, rx = rx, active = true }
    self.watches[#self.watches + 1] = rec

    if opts and opts.replay then
      for _, retained in pairs(self.retained) do
        if topic_matches(topic, retained.topic) then
          tx:send({
            op = 'retain',
            topic = copy_topic(retained.topic),
            payload = retained.payload,
          })
        end
      end
    end

    return {
      recv_op = function()
        return rx:recv_op()
      end,
      unwatch = function()
        rec.active = false
        tx:close('unwatched')
        return true
      end,
      _tx = tx,
      _rx = rx,
    }
  end

  function conn:bind(topic, opts)
    local tx, rx = mailbox.new((opts and opts.queue_len) or 16, { full = 'reject_newest' })
    local rec = { topic = copy_topic(topic), tx = tx, rx = rx, active = true }
    self.bound[topic_key(topic)] = rec

    return {
      recv_op = function()
        return rx:recv_op()
      end,
      unbind = function()
        rec.active = false
        tx:close('unbound')
        return true
      end,
      inject = function(_, req)
        return tx:send(req)
      end,
      _tx = tx,
      _rx = rx,
    }
  end

  function conn:set_call_handler(topic, fn)
    self.call_handlers[topic_key(topic)] = fn
  end

  function conn:call_op(topic, payload, opts)
    local handler = self.call_handlers[topic_key(topic)]
    if not handler then
      return op.always(nil, 'no_handler')
    end

    local reply, err = handler(payload, opts)
    return op.always(reply, err)
  end

  return conn
end

function T.new_state_is_watchable()
  runfibers.run(function()
    local s = rpc_bridge.new_state('link-1')
    local snap = s:snapshot()

    assert(snap.link_id == 'link-1')
    assert(snap.established == false)
    assert(snap.generation == nil)
    assert(snap.exporting == false)
    assert(snap.imported_topics == 0)
    assert(snap.pending_calls == 0)
    assert(snap.inbound_helpers == 0)
    assert(snap.last_err == nil)

    local seen = s:version()
    local changed = s:set_snapshot({
      link_id = 'link-1',
      established = true,
      generation = 7,
      exporting = true,
      imported_topics = 1,
      pending_calls = 2,
      inbound_helpers = 3,
      last_err = 'x',
    })

    assert(changed == true)

    local version, next_snap = fibers.perform(s:changed_op(seen))
    assert(type(version) == 'number')
    assert(next_snap.established == true)
    assert(next_snap.generation == 7)
    assert(next_snap.pending_calls == 2)
  end)
end

function T.rpc_bridge_publishes_and_unretains_owned_topics()
  runfibers.run(function(parent)
    local conn = new_fake_conn()
    local state_conn = new_state_conn()
    local session = make_watchable({
      established = false,
      generation = 0,
    })
    local bridge = rpc_bridge.new_state('link-1')
    local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
    local helper_done_tx, helper_done_rx = mailbox.new(8, { full = 'reject_newest' })

    local scope = assert(parent:child())
    local ok, err = scope:spawn(function()
      rpc_bridge.run({
        link_id = 'link-1',
        conn = conn,
        state_conn = state_conn,
        session = session,
        bridge = bridge,
        rpc_rx = rpc_rx,
        tx_rpc = assert((mailbox.new(8, { full = 'reject_newest' }))),
        helper_done_rx = helper_done_rx,
        helper_done_tx = helper_done_tx,
        member_source = 'member-a',
        rules = {},
      })
    end)
    assert(ok, tostring(err))

    wait_until(function()
      return state_conn.retains[topic_key(topics.state_link_component('link-1', 'bridge'))] ~= nil
    end, 0.2)

    scope:cancel('done')
    fibers.perform(scope:join_op())

    assert(state_conn.unretains[topic_key(topics.state_link_component('link-1', 'bridge'))] == true)
    assert(state_conn.unretains[topic_key(topics.raw_member_state('member-a', 'bridge'))] == true)
  end)
end

function T.rpc_bridge_imports_retained_pub_and_clears_on_session_drop()
  runfibers.run(function(parent)
    local conn = new_fake_conn()
    local state_conn = new_state_conn()
    local session = make_watchable({
      established = true,
      generation = 1,
    })
    local bridge = rpc_bridge.new_state('link-1')

    local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
    local tx_rpc, _tx_rpc_rx = mailbox.new(8, { full = 'reject_newest' })
    local helper_done_tx, helper_done_rx = mailbox.new(8, { full = 'reject_newest' })

    local scope = assert(parent:child())
    local ok, err = scope:spawn(function()
      rpc_bridge.run({
        link_id = 'link-1',
        conn = conn,
        state_conn = state_conn,
        session = session,
        bridge = bridge,
        rpc_rx = rpc_rx,
        tx_rpc = tx_rpc,
        helper_done_rx = helper_done_rx,
        helper_done_tx = helper_done_tx,
        member_source = 'member-a',
        rules = {
          import_rules = {
            {
              local_prefix = topics.raw_member_state('member-a'),
              remote_prefix = { 'state' },
            },
          },
        },
      })
    end)
    assert(ok, tostring(err))

    rpc_tx:send({
      at = fibers.now(),
      frame = {
        type = 'pub',
        topic = { 'state', 'temp' },
        payload = { value = 42 },
        retain = true,
      },
    })

    local imported_topic = topics.raw_member_state('member-a', 'temp')

    wait_until(function()
      return conn.retained[topic_key(imported_topic)] ~= nil
    end, 0.2)

    assert(bridge:snapshot().imported_topics == 1)

    session:set_snapshot({
      established = false,
      generation = 1,
    })

    wait_until(function()
      return conn.unretained[topic_key(imported_topic)] == true
    end, 0.2)

    local snap = bridge:snapshot()
    assert(snap.established == false)
    assert(snap.imported_topics == 0)

    scope:cancel('done')
    fibers.perform(scope:join_op())
  end)
end

function T.rpc_bridge_routes_outbound_call_and_completes_on_reply()
  runfibers.run(function(parent)
    local conn = new_fake_conn()
    local state_conn = new_state_conn()
    local session = make_watchable({
      established = true,
      generation = 7,
    })
    local bridge = rpc_bridge.new_state('link-1')

    local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
    local tx_rpc, tx_rpc_rx = mailbox.new(8, { full = 'reject_newest' })
    local helper_done_tx, helper_done_rx = mailbox.new(8, { full = 'reject_newest' })

    local scope = assert(parent:child())
    local ok, err = scope:spawn(function()
      rpc_bridge.run({
        link_id = 'link-1',
        conn = conn,
        state_conn = state_conn,
        session = session,
        bridge = bridge,
        rpc_rx = rpc_rx,
        tx_rpc = tx_rpc,
        helper_done_rx = helper_done_rx,
        helper_done_tx = helper_done_tx,
        member_source = 'member-a',
        rules = {
          max_pending_calls = 8,
          outbound_call_rules = {
            {
              local_topic = { 'cap', 'diag' },
              remote_topic = { 'cap', 'diag' },
              timeout = 0.5,
            },
          },
        },
      })
    end)
    assert(ok, tostring(err))

    local ep = conn.bound[topic_key({ 'cap', 'diag' })]
    assert(ep ~= nil)

    local req = new_req({ 'cap', 'diag' }, { ask = 'ping' })
    ep.tx:send(req)

    local outbound = nil
    wait_until(function()
      local item = recv_now(tx_rpc_rx)
      if item and item.frame and item.frame.type == 'call' then
        outbound = item.frame
        return true
      end
      return false
    end, 0.2)

    assert(outbound ~= nil)
    assert(outbound.topic[1] == 'cap')
    assert(type(outbound.id) == 'string' and outbound.id ~= '')

    rpc_tx:send({
      at = fibers.now(),
      frame = {
        type = 'reply',
        id = outbound.id,
        ok = true,
        payload = { pong = true },
      },
    })

    wait_until(function()
      return req.replied == true
    end, 0.2)

    assert(req.failed == false)
    assert(req.result.pong == true)
    assert(bridge:snapshot().pending_calls == 0)

    scope:cancel('done')
    fibers.perform(scope:join_op())
  end)
end

function T.rpc_bridge_runs_inbound_helper_and_sends_reply()
  runfibers.run(function(parent)
    local conn = new_fake_conn()
    local state_conn = new_state_conn()
    local session = make_watchable({
      established = true,
      generation = 3,
    })
    local bridge = rpc_bridge.new_state('link-1')

    conn:set_call_handler({ 'svc', 'diag', 'rpc' }, function(payload, opts)
      return { echoed = payload.n, timeout = opts and opts.timeout }, nil
    end)

    local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
    local tx_rpc, tx_rpc_rx = mailbox.new(8, { full = 'reject_newest' })
    local helper_done_tx, helper_done_rx = mailbox.new(8, { full = 'reject_newest' })

    local scope = assert(parent:child())
    local ok, err = scope:spawn(function()
      rpc_bridge.run({
        link_id = 'link-1',
        conn = conn,
        state_conn = state_conn,
        session = session,
        bridge = bridge,
        rpc_rx = rpc_rx,
        tx_rpc = tx_rpc,
        helper_done_rx = helper_done_rx,
        helper_done_tx = helper_done_tx,
        member_source = 'member-a',
        rules = {
          max_inbound_helpers = 8,
          call_timeout_s = 0.5,
          inbound_call_rules = {
            {
              local_topic = { 'svc', 'diag', 'rpc' },
              remote_topic = { 'svc', 'diag', 'rpc' },
              timeout = 0.2,
            },
          },
        },
      })
    end)
    assert(ok, tostring(err))

    rpc_tx:send({
      at = fibers.now(),
      frame = {
        type = 'call',
        id = 'remote-1',
        topic = { 'svc', 'diag', 'rpc' },
        payload = { n = 5 },
      },
    })

    local reply = nil
    wait_until(function()
      local item = recv_now(tx_rpc_rx)
      if item and item.frame and item.frame.type == 'reply' then
        reply = item.frame
        return true
      end
      return false
    end, 0.2)

    assert(reply ~= nil)
    assert(reply.id == 'remote-1')
    assert(reply.ok == true)
    assert(reply.payload.echoed == 5)

    scope:cancel('done')
    fibers.perform(scope:join_op())
  end)
end

return T
