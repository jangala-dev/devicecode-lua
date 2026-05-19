local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local cond   = require 'fibers.cond'
local op     = require 'fibers.op'
local busmod = require 'bus'
local service = require 'services.update.service'
local topics = require 'services.update.topics'
local probe = require 'tests.support.bus_probe'
local store_mod = require 'services.update.job_store_memory'
local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
local function assert_not_nil(v,msg) if v == nil then fail(msg or 'expected non-nil') end end
local function start_service(root_scope, params)
  params = params or {}
  local bus = params.bus or busmod.new(); local svc_conn = bus:connect(); local caller = bus:connect(); local child = assert(root_scope:child())
  local ok, err = child:spawn(function (scope) params=params or {}; params.conn=svc_conn; params.service_id=params.service_id or 'update'; params.watch_config=false; if params.job_store == nil and params.job_store_kind == nil then params.job_store_kind='memory' end; service.run(scope, params) end)
  assert_true(ok, err); fibers.perform(sleep.sleep_op(0.02)); return child, caller, bus
end
function tests.test_manager_create_job_is_scoped_and_updates_status_model()
  fibers.run(function (root_scope)
    local child, caller = start_service(root_scope, { config={ schema='devicecode.update/1', components={ { component='cm5' } } } })
    local reply, err = caller:call(topics.update_manager_rpc('create-job'), { job_id='j1', component='cm5', artifact_ref='artifact-1' }, { timeout=0.5 })
    assert_not_nil(reply, err); assert_eq(reply.ok, true); assert_eq(reply.job.job_id, 'j1')
    local status
    local ok_wait = probe.wait_until(function() status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 }); return status and status.snapshot and status.snapshot.jobs and status.snapshot.jobs.by_id.j1 ~= nil end, { timeout=0.5, interval=0.01 })
    assert_true(ok_wait, 'expected created job to appear in service status'); assert_eq(status.snapshot.jobs.by_id.j1.component, 'cm5')
    child:cancel('test complete')
  end)
end
function tests.test_active_completion_releases_slot_before_later_start_admission()
  fibers.run(function (root_scope)
    local release_first = cond.new(); local started_first = cond.new(); local run_count = 0
    local active_backend = {}
    function active_backend:stage_op(job)
      run_count = run_count + 1
      if job.job_id == 'j1' then
        started_first:signal()
        return release_first:wait_op():wrap(function () return { job='j1' } end)
      end
      return op.always({ job=job.job_id }, nil)
    end
    local child, caller = start_service(root_scope, { config={ schema='devicecode.update/1', components={ { component='cm5' } } }, backend=active_backend })
    assert(caller:call(topics.update_manager_rpc('create-job'), { job_id='j1', component='cm5' }, { timeout=0.5 }))
    assert(caller:call(topics.update_manager_rpc('create-job'), { job_id='j2', component='cm5' }, { timeout=0.5 }))
    assert_true(probe.wait_until(function() local status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 }); return status and status.snapshot.jobs.by_id.j1 and status.snapshot.jobs.by_id.j2 end, { timeout=0.5, interval=0.01 }), 'expected both jobs to be visible')
    local accepted = assert(caller:call(topics.update_manager_rpc('start-job'), { job_id='j1' }, { timeout=0.5 })); assert_eq(accepted.accepted, true); fibers.perform(started_first:wait_op())
    local busy, busy_err = caller:call(topics.update_manager_rpc('start-job'), { job_id='j2' }, { timeout=0.2 }); assert_eq(busy, nil); assert_eq(busy_err, 'slot_busy')
    release_first:signal()
    local accepted2
    local ok_wait = probe.wait_until(function() accepted2 = caller:call(topics.update_manager_rpc('start-job'), { job_id='j2' }, { timeout=0.05 }); return accepted2 and accepted2.accepted == true end, { timeout=0.6, interval=0.01 })
    assert_true(ok_wait, 'expected second start to be admitted after active completion'); assert_eq(run_count >= 2, true)
    local status
    probe.wait_until(function() status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 }); return status and status.snapshot.jobs.by_id.j1 and status.snapshot.jobs.by_id.j1.state == 'awaiting_commit' end, { timeout=0.5, interval=0.01 })
    assert_eq(status.snapshot.jobs.by_id.j1.state, 'awaiting_commit')
    child:cancel('test complete')
  end)
end

function tests.test_commit_job_persists_awaiting_return_before_reconcile()
  fibers.run(function (root_scope)
    local save_log = {}
    local backend = { jobs = {} }
    function backend:load_all_op() return op.always({ jobs = self.jobs, order = {} }, nil) end
    function backend:save_job_op(job)
      save_log[#save_log + 1] = { job_id = job.job_id, state = job.state }
      self.jobs[job.job_id] = job
      return op.always(true, nil)
    end

    local active_backend = {}
    function active_backend:stage_op(job) return op.always({ job_id=job.job_id }, nil) end
    function active_backend:commit_capabilities() return { policy = 'idempotent_by_token' } end
    function active_backend:commit_op(job, ctx) return op.always({ accepted=true, token=ctx.commit_token, job_id=job.job_id }, nil) end
    function active_backend:evaluate_reconcile() return { done=true, tag='reconciled_success', observed={ ok=true } } end

    local child, caller = start_service(root_scope, {
      config={ schema='devicecode.update/1', components={ { component='cm5' } } },
      job_store = backend,
      backend = active_backend,
    })
    assert(caller:call(topics.update_manager_rpc('create-job'), { job_id='j1', component='cm5' }, { timeout=0.5 }))
    assert_true(probe.wait_until(function()
      local status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 })
      return status and status.snapshot.jobs.by_id.j1 ~= nil
    end, { timeout=0.5, interval=0.01 }), 'expected created job')
    assert(caller:call(topics.update_manager_rpc('start-job'), { job_id='j1' }, { timeout=0.5 }))
    assert_true(probe.wait_until(function()
      local status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 })
      return status and status.snapshot.jobs.by_id.j1 and status.snapshot.jobs.by_id.j1.state == 'awaiting_commit'
    end, { timeout=0.5, interval=0.01 }), 'expected staged job')

    local reply = assert(caller:call(topics.update_manager_rpc('commit-job'), { job_id='j1' }, { timeout=0.5 }))
    assert_eq(reply.accepted, true)
    local status
    assert_true(probe.wait_until(function()
      status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 })
      return status and status.snapshot.jobs.by_id.j1 and status.snapshot.jobs.by_id.j1.state == 'succeeded'
    end, { timeout=0.8, interval=0.01 }), 'expected reconcile success after commit')

    local saw_awaiting_return, saw_succeeded = false, false
    for _, row in ipairs(save_log) do
      if row.job_id == 'j1' and row.state == 'awaiting_return' then saw_awaiting_return = true end
      if row.job_id == 'j1' and row.state == 'succeeded' then saw_succeeded = true end
    end
    assert_true(saw_awaiting_return, 'commit accepted boundary must be durably saved')
    assert_true(saw_succeeded, 'reconcile result must be saved')
    child:cancel('test complete')
  end)
end

function tests.test_restart_adoption_keeps_awaiting_commit_committable()
  fibers.run(function (root_scope)
    local initial_jobs = { jobs = { j1 = { job_id='j1', component='cm5', state='awaiting_commit', created_seq=1, updated_seq=1 } } }
    local child, caller = start_service(root_scope, {
      config={ schema='devicecode.update/1', components={ { component='cm5' } } },
      initial_jobs = initial_jobs,
      backend = {
        stage_op = function () return op.always({}, nil) end,
        commit_capabilities = function () return { policy = 'idempotent_by_token' } end,
        commit_op = function (_, job, ctx) return op.always({ accepted=true, token=ctx.commit_token }, nil) end,
        evaluate_reconcile = function () return { done=true, tag='reconciled_success', observed={ ok=true } } end,
      },
    })
    local reply = assert(caller:call(topics.update_manager_rpc('commit-job'), { job_id='j1' }, { timeout=0.5 }))
    assert_eq(reply.accepted, true)
    assert_true(probe.wait_until(function()
      local status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 })
      return status and status.snapshot.jobs.by_id.j1 and status.snapshot.jobs.by_id.j1.state == 'succeeded'
    end, { timeout=0.8, interval=0.01 }), 'awaiting_commit should remain committable after adoption')
    child:cancel('test complete')
  end)
end

function tests.test_restart_adoption_starts_reconcile_for_awaiting_return()
  fibers.run(function (root_scope)
    local ran_reconcile = false
    local initial_jobs = { jobs = { j1 = { job_id='j1', component='cm5', state='awaiting_return', created_seq=1, updated_seq=1 } } }
    local child, caller = start_service(root_scope, {
      config={ schema='devicecode.update/1', components={ { component='cm5' } } },
      initial_jobs = initial_jobs,
      backend = {
        stage_op = function () return op.always({}, nil) end,
        evaluate_reconcile = function () ran_reconcile = true; return { done=true, tag='reconciled_success', observed={ ok=true } } end,
      },
    })
    assert_true(probe.wait_until(function()
      local status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 })
      return ran_reconcile and status and status.snapshot.jobs.by_id.j1 and status.snapshot.jobs.by_id.j1.state == 'succeeded'
    end, { timeout=0.8, interval=0.01 }), 'awaiting_return should start reconcile after adoption')
    child:cancel('test complete')
  end)
end


function tests.test_slow_job_runtime_load_keeps_public_service_responsive()
  fibers.run(function (root_scope)
    local load_gate = cond.new()
    local backend = { loaded = false, jobs = {} }
    function backend:load_all_op()
      return load_gate:wait_op():wrap(function ()
        self.loaded = true
        return { jobs = self.jobs, order = {} }, nil
      end)
    end
    function backend:save_job_op(job)
      self.jobs[job.job_id] = job
      return op.always(true, nil)
    end
    local child, caller = start_service(root_scope, {
      config={ schema='devicecode.update/1', components={ { component='cm5' } } },
      job_store = backend,
    })
    local status = assert(caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.5 }))
    assert_eq(status.ok, true)
    assert_eq(status.snapshot.state, 'starting')
    local created, create_err = caller:call(topics.update_manager_rpc('create-job'), { job_id='j1', component='cm5' }, { timeout=0.5 })
    assert_eq(created, nil)
    assert_eq(create_err, 'job_runtime_not_ready')
    load_gate:signal()
    assert_true(probe.wait_until(function()
      local s = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 })
      return s and s.snapshot and s.snapshot.state == 'running'
    end, { timeout=0.6, interval=0.01 }), 'service should become running after job load')
    child:cancel('test complete')
  end)
end

local function bind_fake_control_store(scope, bus, backing)
  backing = backing or {}
  local conn = bus:connect()
  local methods = { 'list', 'get', 'put', 'delete' }
  for _, method in ipairs(methods) do
    local loop_method = method
    local ep = assert(conn:bind({ 'cap', 'control-store', 'update', 'rpc', loop_method }))
    scope:spawn(function ()
      while true do
        local req = fibers.perform(ep:recv_op())
        if req == nil then return end
        local p = req.payload or {}
        if loop_method == 'list' then
          local keys = {}
          local prefix = p.prefix or ''
          for k in pairs(backing) do
            if k:sub(1, #prefix) == prefix then keys[#keys + 1] = k end
          end
          table.sort(keys)
          req:reply({ ok = true, reason = keys })
        elseif loop_method == 'get' then
          if backing[p.key] == nil then req:reply({ ok = false, reason = 'not found' }) else req:reply({ ok = true, reason = backing[p.key] }) end
        elseif loop_method == 'put' then
          backing[p.key] = p.data
          req:reply({ ok = true, reason = nil })
        elseif loop_method == 'delete' then
          backing[p.key] = nil
          req:reply({ ok = true, reason = nil })
        end
      end
    end)
  end
  return backing
end

function tests.test_default_job_store_uses_control_store_and_reloads_after_restart()
  fibers.run(function (root_scope)
    local bus = busmod.new()
    local control_scope = assert(root_scope:child())
    local backing = bind_fake_control_store(control_scope, bus, {})
    local child, caller = start_service(root_scope, {
      bus = bus,
      job_store_kind = 'control-store',
      config = { schema='devicecode.update/1', components={ { component='cm5' } } },
    })
    local created, create_err = caller:call(topics.update_manager_rpc('create-job'), { job_id='j-persist', component='cm5' }, { timeout=0.5 })
    assert_not_nil(created, create_err)
    assert_eq(created.ok, true)
    assert_true(probe.wait_until(function()
      local status = caller:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 })
      return status and status.snapshot and status.snapshot.jobs.by_id['j-persist'] ~= nil
    end, { timeout=0.5, interval=0.01 }), 'expected first service to persist job')
    child:cancel('first service complete')
    fibers.perform(child:join_op())

    local saw_key_after_first = false
    for k in pairs(backing) do if k:sub(1, 11) == 'update-job-' then saw_key_after_first = true end end
    assert_true(saw_key_after_first, 'expected first service to persist job in control-store keyspace')

    local child2, caller2 = start_service(root_scope, {
      bus = bus,
      job_store_kind = 'control-store',
      config = { schema='devicecode.update/1', components={ { component='cm5' } } },
    })
    assert_true(probe.wait_until(function()
      local status = caller2:call(topics.update_manager_rpc('status'), {}, { timeout=0.05 })
      return status and status.snapshot and status.snapshot.jobs.by_id['j-persist'] ~= nil
    end, { timeout=0.5, interval=0.01 }), 'expected restarted service to reload persisted job')
    child2:cancel('test complete')
    fibers.perform(child2:join_op())
    control_scope:cancel('test complete')
    fibers.perform(control_scope:join_op())
  end)
end

return tests
