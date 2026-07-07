local repo = require 'services.update.job_repository'
local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
local function assert_not_nil(v,msg) if v == nil then fail(msg or 'expected non-nil') end end
function tests.test_new_job_normalises_and_snapshots_are_copies()
  local state = assert(repo.new_state())
  local job = assert(repo.new_job({ job_id='j1', component='cm5', artifact_ref='a1' }, { generation=7, seq=1 }))
  assert(repo.upsert(state, job))
  assert_eq(job.phase, nil)
  assert_eq(job.stage, nil)
  local snap = repo.snapshot(state)
  assert_eq(snap.count, 1); assert_eq(snap.by_id.j1.component, 'cm5')
  assert_eq(snap.by_id.j1.phase, nil)
  assert_eq(snap.by_id.j1.stage, nil)
  snap.by_id.j1.component = 'mutated'
  assert_eq(repo.get(state, 'j1').component, 'cm5')
end

function tests.test_job_repository_rejects_phase_and_stage_aliases()
  local state = assert(repo.new_state())
  local job, err = repo.new_job({ job_id='j1', component='cm5' }, { seq=repo.next_sequence(state) })
  assert_not_nil(job, err)
  job.phase = 'created'
  local ok_job, jerr = repo.upsert(state, job)
  assert_eq(ok_job, nil)
  assert_not_nil(jerr)

  job.phase = nil
  assert(repo.upsert(state, job))
  local _, perr = repo.patch(state.jobs.j1, { phase = 'stage' }, { seq=repo.next_sequence(state) })
  assert_not_nil(perr)
end

function tests.test_lifecycle_helpers_do_not_perform_work()
  local state = assert(repo.new_state())
  local job = assert(repo.new_job({ job_id='j1', component='cm5' }, { seq=repo.next_sequence(state) }))
  repo.upsert(state, job); local stored = state.jobs.j1
  repo.mark_staging(stored, { seq=repo.next_sequence(state), reason='start' }); assert_eq(stored.state, 'staging'); assert_eq(stored.phase, nil); assert_eq(stored.stage, nil)
  repo.mark_awaiting_commit(stored, { image='ok' }, { seq=repo.next_sequence(state) }); assert_eq(stored.state, 'awaiting_commit'); assert_eq(stored.next_step, 'commit'); assert_eq(stored.phase, nil); assert_eq(stored.stage, nil)
  repo.mark_terminal(stored, 'failed', 'boom', nil, { seq=repo.next_sequence(state) }); assert_true(repo.is_terminal(stored.state)); assert_not_nil(stored.last_event)
end
function tests.test_terminal_compaction_drops_operational_internals()
  local job = repo.compact_job({
    job_id='j1', component='cm5', state='succeeded', expected_image_id='img',
    created_seq=1, updated_seq=2, next_step='commit', generation=9,
    active_token='tok', active_intent={ token='tok', phase='stage' }, active={ token='tok', phase='stage' },
    adoption={ action='kept_committable' }, commit_attempt={ token='ct' },
    stage_result={ reply={ transfer={ xfer_id='x1', sent_bytes=12 } }, preflight={ metadata={ large=true } } },
    result={ ok=true, tag='ok' }, history={ { seq=2, state='succeeded', reason='done' } },
  })
  assert_eq(job.next_step, nil)
  assert_eq(job.generation, nil)
  assert_eq(job.active_token, nil)
  assert_eq(job.active_intent, nil)
  assert_eq(job.active, nil)
  assert_eq(job.adoption, nil)
  assert_not_nil(job.commit_attempt)
  assert_eq(job.commit_attempt.token, 'ct')
  assert_eq(job.stage_result, nil)
  assert_not_nil(job.transfer)
  assert_eq(job.transfer.xfer_id, 'x1')
  assert_eq(job.result.ok, true)
  assert_eq(job.last_event.reason, 'done')
end

function tests.test_active_compaction_preserves_policy_for_auto_commit()
  local job = repo.compact_job({
    job_id='j1', component='mcu', state='awaiting_commit', expected_image_id='img',
    created_seq=1, updated_seq=2, next_step='commit', generation=9,
    policy={
      job_id='j1', create_if='image_differs', start='auto', commit='auto',
      reconcile='required', supersede='same_job_if_image_changed',
    },
  })
  assert_not_nil(job.policy)
  assert_eq(job.policy.commit, 'auto')
  assert_eq(job.policy.start, 'auto')
  assert_eq(job.policy.reconcile, 'required')
end

function tests.test_new_job_preserves_policy_for_active_lifecycle()
  local job = assert(repo.new_job({
    job_id='j1', component='mcu', expected_image_id='img', artifact_ref='a1',
    policy={ start='auto', commit='auto', reconcile='required' },
  }, { seq=1 }))
  assert_not_nil(job.policy)
  assert_eq(job.policy.commit, 'auto')
end

return tests
