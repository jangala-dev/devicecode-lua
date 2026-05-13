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
  local snap = repo.snapshot(state)
  assert_eq(snap.count, 1); assert_eq(snap.by_id.j1.component, 'cm5')
  snap.by_id.j1.component = 'mutated'
  assert_eq(repo.get(state, 'j1').component, 'cm5')
end
function tests.test_lifecycle_helpers_do_not_perform_work()
  local state = assert(repo.new_state())
  local job = assert(repo.new_job({ job_id='j1', component='cm5' }, { seq=repo.next_sequence(state) }))
  repo.upsert(state, job); local stored = state.jobs.j1
  repo.mark_staging(stored, { seq=repo.next_sequence(state), reason='start' }); assert_eq(stored.state, 'staging')
  repo.mark_awaiting_commit(stored, { image='ok' }, { seq=repo.next_sequence(state) }); assert_eq(stored.next_step, 'commit')
  repo.mark_terminal(stored, 'failed', 'boom', nil, { seq=repo.next_sequence(state) }); assert_true(repo.is_terminal(stored.state)); assert_not_nil(stored.history[1])
end
return tests
