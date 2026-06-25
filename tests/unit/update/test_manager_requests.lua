local fibers = require 'fibers'
local cond = require 'fibers.cond'
local op = require 'fibers.op'
local manager_requests = require 'services.update.manager_requests'
local store_mod = require 'services.update.job_store_memory'
local job_runtime = require 'services.update.job_runtime'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
local function assert_nil(v,msg) if v ~= nil then fail(msg or ('expected nil, got '..tostring(v))) end end
local function assert_not_nil(v,msg) if v == nil then fail(msg or 'expected non-nil') end end

local function request(payload)
  local c = cond.new(); local req = { payload=payload, done=false }
  function req:reply(v) self.done=true; self.ok=true; self.value=v; c:signal(); return true end
  function req:fail(e) self.done=true; self.ok=false; self.err=e; c:signal(); return true end
  function req:wait_op() return op.guard(function() if self.done then return op.always(self.ok,self.value,self.err) end; return c:wait_op():wrap(function() return self.ok,self.value,self.err end) end) end
  return req
end

local function start_jobs(scope, store, initial)
  local jobs = assert(job_runtime.start(scope, {
    service_id = 'update',
    store = store or store_mod.new(initial),
    initial_jobs = initial,
  }))
  local ready, err = fibers.perform(jobs:ready_op())
  assert_true(ready, err)
  return jobs
end

local function initial_with(job)
  return { jobs = { [job.job_id] = job }, order = { job.job_id }, next_seq = 10 }
end

function tests.test_create_job_scope_replies_and_returns_completion_fact()
  fibers.run(function ()
    local req = request({ method='create_job', job_id='j1', component='cm5', artifact_ref='a1' })
    local st, rep, result = fibers.run_scope(function (scope)
      local jobs = start_jobs(scope, store_mod.new())
      local out = manager_requests.create_job(scope, { request=req, jobs=jobs, config={ components={ cm5={component='cm5'} } }, generation=3 })
      jobs:cancel('test complete')
      return out
    end)
    assert_eq(st, 'ok')
    assert_eq(result.status, 'persisted')
    assert_eq(result.tag, 'job_created')
    local ok, value = fibers.perform(req:wait_op()); assert_true(ok); assert_eq(value.job.job_id, 'j1')
  end)
end

function tests.test_create_job_rejects_unknown_component_without_throwing()
  fibers.run(function ()
    local req = request({ method='create_job', job_id='j1', component='mcu' })
    local st, rep, result = fibers.run_scope(function (scope) return manager_requests.create_job(scope, { request=req, config={ components={ cm5={component='cm5'} } }, seq=1 }) end)
    assert_eq(st, 'ok'); assert_eq(result.tag, 'manager_request_rejected')
    local ok, value, err = fibers.perform(req:wait_op()); assert_eq(ok, false); assert_eq(err, 'unknown_component')
  end)
end

function tests.test_start_job_persists_active_intent_without_starting_active_work()
  fibers.run(function ()
    local saves = {}
    local initial = initial_with({ job_id = 'j1', component = 'cm5', state = 'created' })
    local store = {
      load_all_op = function () return op.always(initial, nil) end,
      save_job_op = function (_, job) saves[#saves + 1] = job; return op.always(true, nil) end,
    }

    local req = request({ method = 'start_job', job_id = 'j1' })
    local st, _, result = fibers.run_scope(function (scope)
      local jobs = start_jobs(scope, store)
      local out = manager_requests.start_job(scope, {
        request = req,
        jobs = jobs,
        job_id = 'j1',
        phase = 'stage',
        generation = 1,
      })
      jobs:cancel('test complete')
      return out
    end)

    assert_eq(st, 'ok')
    assert_eq(result.status, 'persisted')
    assert_eq(result.tag, 'job_started')
    assert_eq(#saves, 1, 'start request should durably save active intent')
    assert_eq(saves[1].state, 'staging')
    assert_not_nil(saves[1].active_intent, 'active intent should be durable')
    assert_eq(saves[1].active_intent.phase, 'stage')
    local ok, value = fibers.perform(req:wait_op())
    assert_eq(ok, true)
    assert_eq(value.accepted, true)
    assert_eq(value.token, result.token)
  end)
end

function tests.test_second_start_rejected_while_durable_active_intent_exists()
  fibers.run(function ()
    local initial = { jobs = {
      j1 = { job_id = 'j1', component = 'cm5', state = 'staging', active_token='tok-1', active_intent={ token='tok-1', phase='stage' }, created_seq=1, updated_seq=1 },
      j2 = { job_id = 'j2', component = 'cm5', state = 'created', created_seq=2, updated_seq=2 },
    }, order = { 'j1', 'j2' }, next_seq = 10 }
    local req = request({ method = 'start_job', job_id = 'j2' })
    local st, _, result = fibers.run_scope(function (scope)
      local jobs = start_jobs(scope, store_mod.new(initial), initial)
      local out = manager_requests.start_job(scope, {
        request = req,
        jobs = jobs,
        job_id = 'j2',
        phase = 'stage',
        generation = 1,
      })
      jobs:cancel('test complete')
      return out
    end)
    assert_eq(st, 'ok')
    assert_eq(result.tag, 'manager_request_rejected')
    assert_eq(result.reason, 'slot_busy')
    local ok, _, err = fibers.perform(req:wait_op())
    assert_eq(ok, false)
    assert_eq(err, 'slot_busy')
  end)
end

function tests.test_start_job_caller_cancellation_after_transition_admission_does_not_cancel_durable_transition()
  fibers.run(function ()
    local save_entered = cond.new()
    local save_release = cond.new()
    local saves = {}
    local initial = initial_with({ job_id = 'j1', component = 'cm5', state = 'created' })
    local store = {
      load_all_op = function () return op.always(initial, nil) end,
      save_job_op = function (_, job)
        saves[#saves + 1] = job
        save_entered:signal()
        return save_release:wait_op():wrap(function () return true, nil end)
      end,
    }

    local req = request({ method = 'start_job', job_id = 'j1' })
    req.reply_count = 0
    req.fail_count = 0
    local original_reply = req.reply
    local original_fail = req.fail
    function req:reply(v) self.reply_count = self.reply_count + 1; return original_reply(self, v) end
    function req:fail(e) self.fail_count = self.fail_count + 1; return original_fail(self, e) end

    local st, _, result = fibers.run_scope(function (scope)
      local jobs = start_jobs(scope, store)
      local request_scope = assert(scope:child())
      local ok, spawn_err = request_scope:spawn(function (rs)
        manager_requests.start_job(rs, {
          request = req,
          jobs = jobs,
          job_id = 'j1',
          phase = 'stage',
          generation = 1,
        })
      end)
      assert_true(ok, spawn_err)

      fibers.perform(save_entered:wait_op())
      local transitions_at_admission = jobs:transition_snapshot()
      local transition_id = transitions_at_admission.order[1]
      local admitted = transitions_at_admission.by_id[transition_id]
      assert_eq(admitted.state, 'persisting')
      assert_true(admitted.admitted, 'transition should be admitted before caller cancellation')

      request_scope:cancel('caller_cancelled')
      local cst = fibers.perform(request_scope:join_op())
      assert_eq(cst, 'cancelled')
      assert_eq(req.fail_count, 1)
      assert_eq(req.reply_count, 0)
      assert_eq(req.err, 'caller_cancelled')

      local seen = jobs:version()
      save_release:signal()
      for _ = 1, 8 do
        local job = jobs:get('j1')
        if job and job.state == 'staging' then break end
        local version = fibers.perform(jobs:changed_op(seen))
        seen = version or seen
      end

      local job = jobs:get('j1')
      local transitions = jobs:transition_snapshot()
      local outcome = jobs:transition_outcome(transition_id)
      jobs:cancel('test complete')
      return { job = job, transitions = transitions, transition_id = transition_id, outcome = outcome, saves = saves }
    end)

    assert_eq(st, 'ok')
    assert_eq(result.job.state, 'staging')
    assert_not_nil(result.job.active_intent, 'durable active intent should be persisted despite caller cancellation')
    assert_eq(result.transitions.by_id[result.transition_id].state, 'persisted')
    assert_eq(result.outcome.status, 'persisted')
    assert_eq(#result.saves, 1)
  end)
end


function tests.test_create_job_requires_artifact_ref()
  fibers.run(function ()
    local req = request({ method='create_job', job_id='j-missing-artifact', component='cm5' })
    local st, _, result = fibers.run_scope(function (scope)
      local jobs = start_jobs(scope, store_mod.new())
      local out = manager_requests.create_job(scope, {
        request = req,
        jobs = jobs,
        config = { components = { cm5 = { component = 'cm5' } } },
        generation = 1,
      })
      jobs:cancel('test complete')
      return out
    end)
    assert_eq(st, 'ok')
    assert_eq(result.tag, 'manager_request_rejected')
    assert_eq(result.reason, 'artifact_ref_required')
    local ok, _, err = fibers.perform(req:wait_op())
    assert_eq(ok, false)
    assert_eq(err, 'artifact_ref_required')
  end)
end

return tests
