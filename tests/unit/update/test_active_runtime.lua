local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'
local op = require 'fibers.op'
local active = require 'services.update.active_runtime'
local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
local function assert_nil(v,msg) if v ~= nil then fail(msg or ('expected nil, got '..tostring(v))) end end
local function assert_not_nil(v,msg) if v == nil then fail(msg or 'expected non-nil') end end

local function stage_backend(result)
  return { stage_op = function () return op.always(result or { ok = true }, nil) end }
end
local function transition_handle(result)
  return { outcome_op = function () return op.always(result or { status = 'persisted' }, nil) end }
end
function tests.test_claim_rejects_busy_and_completion_releases_slot()
  fibers.run(function (scope)
    local state = active.new_state(); local done_tx, done_rx = mailbox.new(8, { full='reject_newest' })
    local lease = assert(active.claim(state, { job_id='j1', generation=1, phase='stage' }))
    local second, err = active.claim(state, { job_id='j2', generation=1, phase='stage' }); assert_nil(second); assert_eq(err, 'slot_busy')
    local handle = assert(active.start_work(scope, state, { lease=lease, done_tx=done_tx, job={ job_id='j1', component='cm5' }, backend=stage_backend({ ok=true }) }))
    assert_not_nil(handle)
    local ev = fibers.perform(done_rx:recv_op()); assert_eq(ev.kind, 'active_job_done'); assert_eq(ev.status, 'ok')
    assert_true(active.apply_completion(state, ev)); assert_not_nil(state.active); assert_eq(state.active.status, 'completed_pending_persist')
    local busy, busy_err = active.claim(state, { job_id='j2', generation=1, phase='stage' }); assert_nil(busy); assert_eq(busy_err, 'slot_busy')
    assert_true(active.release_completed(state, ev.token)); assert_nil(state.active)
    assert_not_nil(active.claim(state, { job_id='j2', generation=1, phase='stage' }))
  end)
end

function tests.test_lease_release_clears_unstarted_slot_only()
  local state = active.new_state()
  local lease = assert(active.claim(state, { job_id='j1', generation=1, phase='stage' }))
  local ok = assert(lease:release('never_started'))
  assert_eq(ok, true)
  assert_nil(state.active)
  assert_eq(state.stats.released, 1)
  assert_not_nil(active.claim(state, { job_id='j2', generation=1, phase='stage' }))
end

function tests.test_handed_off_lease_cannot_release_running_slot()
  local state = active.new_state()
  local lease = assert(active.claim(state, { job_id='j1', generation=1, phase='stage' }))
  assert_true(lease:handoff())
  local ok, err = lease:release('too_late')
  assert_eq(ok, false)
  assert_eq(err, 'transferred')
  assert_not_nil(state.active)
end

function tests.test_stale_completion_does_not_release_current_slot()
  local state = active.new_state(); assert(active.claim(state, { job_id='j1', generation=1, phase='stage' }))
  local ok, err = active.apply_completion(state, { kind='active_job_done', job_id='j1', generation=1, phase='stage', token='wrong', status='ok', result={ tag='staged' } })
  assert_eq(ok, false); assert_eq(err, 'stale'); assert_not_nil(state.active); assert_eq(state.stats.stale, 1)
end

function tests.test_local_observer_is_notified_after_authoritative_completion_admission()
  fibers.run(function (scope)
    local state = active.new_state()
    local done_tx, done_rx = mailbox.new(8, { full='reject_newest' })
    local observer_scope = assert(scope:child())
    local lease = assert(active.claim(state, { job_id='j1', generation=1, phase='stage' }))
    local handle = assert(active.start_work(scope, state, {
      lease = lease,
      done_tx = done_tx,
      local_observer_scope = observer_scope,
      job={ job_id='j1', component='cm5' },
      backend=stage_backend({ ok=true }),
    }))

    local authoritative = fibers.perform(done_rx:recv_op())
    assert_eq(authoritative.kind, 'active_job_done')
    assert_eq(authoritative.status, 'ok')

    local observed = fibers.perform(handle:outcome_op())
    assert_eq(observed.kind, 'active_job_done')
    assert_eq(observed.token, authoritative.token)
  end)
end


function tests.test_component_stores_completion_before_reporting_to_service()
  fibers.run(function (scope)
    local service_tx, service_rx = mailbox.new(8, { full = 'reject_newest' })
    local fake_jobs = { admit_transition = function () return { outcome_op = function () return fibers.never() end }, nil end }
    local component = assert(active.start_component(scope, {
      service_id = 'update',
      done_tx = service_tx,
      work_scope = scope,
      jobs = fake_jobs,
    }))
    local lease = assert(component:claim({ job_id='j1', generation=1, phase='stage' }))
    assert(component:start_work({
      lease = lease,
      job={ job_id='j1', component='cm5' },
      backend=stage_backend({ ok=true }),
    }))
    local ev = fibers.perform(service_rx:recv_op())
    assert_eq(ev.kind, 'active_runtime_changed')
    assert_eq(ev.reason, 'active_job_completed')
    assert_not_nil(active.completion(component:state(), ev.token), 'completion should be stored before report')
    assert_not_nil(component:state().active)
    assert_eq(component:state().active.status, 'completed_pending_persist')
    component:release_completed(ev.token, 'test persisted')
    assert_nil(component:state().active)
    component:cancel('test complete')
  end)
end

function tests.test_component_apply_start_failure_keeps_stored_completion_and_fails_component()
  fibers.run(function (scope)
    local service_tx, service_rx = mailbox.new(8, { full = 'reject_newest' })
    local component = assert(active.start_component(scope, {
      service_id = 'update',
      done_tx = service_tx,
      work_scope = scope,
      jobs = {},
    }))

    local lease = assert(component:claim({ job_id = 'j1', generation = 1, phase = 'stage' }))
    assert(component:start_work({
      lease = lease,
      job={ job_id='j1', component='cm5' },
      backend=stage_backend({ ok=true }),
    }))

    local completed = fibers.perform(service_rx:recv_op())
    assert_eq(completed.kind, 'active_runtime_changed')
    assert_eq(completed.reason, 'active_job_completed')
    assert_not_nil(active.completion(component:state(), completed.token), 'completion should be stored before apply starts')
    assert_not_nil(component:state().active)
    assert_eq(component:state().active.status, 'completed_pending_persist')

    local failed = fibers.perform(service_rx:recv_op())
    assert_eq(failed.kind, 'component_done')
    assert_eq(failed.component, 'active_runtime')
    assert_eq(failed.status, 'failed')
    assert_eq(failed.primary, 'job_runtime_unavailable')
    assert_not_nil(active.completion(component:state(), completed.token), 'stored completion should remain accounted for')
    assert_not_nil(component:state().active, 'slot should not be silently released when apply cannot start')
  end)
end

function tests.test_component_apply_failure_after_start_keeps_completion_and_reports_failure()
  fibers.run(function (scope)
    local service_tx, service_rx = mailbox.new(8, { full = 'reject_newest' })
    local fake_jobs = {
      admit_transition = function ()
        return transition_handle({ status = 'failed', reason = 'save_failed' }), nil
      end,
    }
    local component = assert(active.start_component(scope, {
      service_id = 'update',
      done_tx = service_tx,
      work_scope = scope,
      jobs = fake_jobs,
    }))

    local lease = assert(component:claim({ job_id = 'j1', generation = 1, phase = 'stage' }))
    assert(component:start_work({
      lease = lease,
      job={ job_id='j1', component='cm5' },
      backend=stage_backend({ ok=true }),
    }))

    local completed = fibers.perform(service_rx:recv_op())
    assert_eq(completed.kind, 'active_runtime_changed')
    assert_eq(completed.reason, 'active_job_completed')
    assert_not_nil(active.completion(component:state(), completed.token), 'completion should be stored before durable apply')

    local apply_failed = fibers.perform(service_rx:recv_op())
    assert_eq(apply_failed.kind, 'active_runtime_changed')
    assert_eq(apply_failed.reason, 'active_job_apply_failed')
    assert_eq(apply_failed.error, 'save_failed')
    assert_eq(component:state().active, nil, 'failed durable apply policy should release completed slot explicitly')
    assert_not_nil(active.completion(component:state(), completed.token), 'stored completion should remain available after apply failure')

    local failed = fibers.perform(service_rx:recv_op())
    assert_eq(failed.kind, 'component_done')
    assert_eq(failed.component, 'active_runtime')
    assert_eq(failed.status, 'failed')
    assert_eq(failed.primary, 'save_failed')
  end)
end

function tests.test_component_auto_commit_policy_admits_commit_after_stage_apply()
  fibers.run(function (scope)
    local service_tx, service_rx = mailbox.new(16, { full = 'reject_newest' })
    local seen = {}
    local fake_jobs = {
      admit_transition = function (_, cmd)
        seen[#seen + 1] = cmd
        if cmd.kind == 'apply_active_result' then
          return transition_handle({
            status = 'persisted',
            job = { job_id = 'j1', component = 'cm5', generation = 1, state = 'awaiting_commit', policy = { commit = 'auto' } },
          }), nil
        elseif cmd.kind == 'start_job' then
          return transition_handle({ status = 'persisted', job_id = cmd.job_id, phase = cmd.phase, token = 'commit-token', job = { job_id = cmd.job_id, component = 'cm5', state = 'committing' } }), nil
        end
        return transition_handle({ status = 'rejected', reason = 'unexpected' }), nil
      end,
      list = function () return {} end,
    }
    local component = assert(active.start_component(scope, {
      service_id = 'update',
      done_tx = service_tx,
      work_scope = scope,
      jobs = fake_jobs,
    }))
    local lease = assert(component:claim({ job_id = 'j1', generation = 1, phase = 'stage' }))
    assert(component:start_work({
      lease = lease,
      job = { job_id='j1', component='cm5', generation = 1, policy = { commit = 'auto' } },
      backend = stage_backend({ ok=true }),
    }))
    local completed = fibers.perform(service_rx:recv_op())
    assert_eq(completed.reason, 'active_job_completed')
    local applied = fibers.perform(service_rx:recv_op())
    assert_eq(applied.reason, 'active_job_applied')
    local auto = fibers.perform(service_rx:recv_op())
    assert_eq(auto.reason, 'policy_auto_commit_started')
    assert_eq(seen[1].kind, 'apply_active_result')
    assert_eq(seen[2].kind, 'start_job')
    assert_eq(seen[2].phase, 'commit')
    assert_eq(seen[2].reason, 'policy_auto_commit')
    component:cancel('test complete')
  end)
end

return tests
