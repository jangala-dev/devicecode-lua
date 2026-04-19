local fibers    = require 'fibers'
local busmod    = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'
local update    = require 'services.update'
local sleep_mod = require 'fibers.sleep'
local safe      = require 'coxpcall'

local T = {}

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

local function start_fs_state_cap(scope, conn, storage)
  conn:retain({ 'cap', 'fs', 'state', 'state' }, 'added')
  conn:retain({ 'cap', 'fs', 'state', 'meta' }, { offerings = { read = true, write = true } })

  local read_ep = conn:bind({ 'cap', 'fs', 'state', 'rpc', 'read' }, { queue_len = 32 })
  local write_ep = conn:bind({ 'cap', 'fs', 'state', 'rpc', 'write' }, { queue_len = 32 })

  bind_reply_loop(scope, read_ep, function(payload)
    local data = storage[payload.filename]
    if data == nil then
      return { ok = false, reason = 'ENOENT' }
    end
    return { ok = true, reason = data }
  end)

  bind_reply_loop(scope, write_ep, function(payload)
    storage[payload.filename] = payload.data
    return { ok = true, reason = '' }
  end)
end

local function wait_service_running(conn, name)
  assert(probe.wait_until(function()
    local okp, payload = safe.pcall(function()
      return probe.wait_payload(conn, { 'svc', name, 'status' }, { timeout = 0.02 })
    end)
    return okp and type(payload) == 'table' and payload.state == 'running'
  end, { timeout = 0.75, interval = 0.01 }))
end

function T.update_service_creates_applies_and_reconciles_job_via_device_proxy()
  runfibers.run(function(scope)
    local orig_sleep = sleep_mod.sleep
    sleep_mod.sleep = function(dt)
      return orig_sleep(math.min(dt, 0.01))
    end
    fibers.current_scope():finally(function()
      sleep_mod.sleep = orig_sleep
    end)

    local bus = busmod.new()
    local caller = bus:connect()
    local fs_conn = bus:connect()
    local device_conn = bus:connect()
    local storage = {}

    start_fs_state_cap(scope, fs_conn, storage)

    local versions = { mcu = 'mcu-v0' }
    local device_status_ep = device_conn:bind({ 'cmd', 'device', 'component', 'status' }, { queue_len = 32 })
    local device_update_ep = device_conn:bind({ 'cmd', 'device', 'component', 'update' }, { queue_len = 32 })

    bind_reply_loop(scope, device_status_ep, function(payload)
      return { ok = true, component = payload.component, state = { version = versions[payload.component] or 'unknown' } }
    end)
    bind_reply_loop(scope, device_update_ep, function(payload)
      if payload.op == 'prepare' then
        return { ok = true, prepared = true }
      elseif payload.op == 'stage' then
        return { ok = true, staged = payload.args.artifact, expected_version = payload.args.expected_version }
      elseif payload.op == 'commit' then
        versions[payload.component] = 'mcu-v1'
        return { ok = true, started = true }
      end
      return nil, 'unsupported_op'
    end)

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'update')

    local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
      target = 'mcu',
      artifact = 'mcu.uf2',
      expected_version = 'mcu-v1',
      metadata = { channel = 'test' },
    }, { timeout = 0.5 })
    assert(cerr == nil)
    assert(created.ok == true)
    local job = created.job
    assert(type(job.job_id) == 'string')
    assert(job.state == 'available')

    local applied, aerr = caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = job.job_id }, { timeout = 1.0 })
    assert(aerr == nil)
    assert(applied.ok == true)

    assert(probe.wait_until(function()
      local okp, state = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
      end)
      return okp and type(state) == 'table' and type(state.job) == 'table' and state.job.state == 'succeeded'
    end, { timeout = 0.75, interval = 0.01 }))

    local got, gerr = caller:call({ 'cmd', 'update', 'job', 'get' }, { job_id = job.job_id }, { timeout = 0.5 })
    assert(gerr == nil)
    assert(got.ok == true)
    assert(got.job.state == 'succeeded')
    assert(type(got.job.result) == 'table')
    assert(got.job.result.version == 'mcu-v1')

    local listed, lerr = caller:call({ 'cmd', 'update', 'job', 'list' }, {}, { timeout = 0.5 })
    assert(lerr == nil)
    assert(listed.ok == true)
    assert(#listed.jobs == 1)
    assert(listed.jobs[1].job_id == job.job_id)

    assert(type(storage['update-jobs.json']) == 'string')
  end, { timeout = 3.0 })
end

return T
