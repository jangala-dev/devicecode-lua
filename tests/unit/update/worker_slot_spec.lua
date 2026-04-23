local fibers = require 'fibers'
local runfibers = require 'tests.support.run_fibers'
local pulse = require 'fibers.pulse'
local worker_slot_mod = require 'services.update.worker_slot'

local T = {}

local function fake_ctx()
  local state = { store = { jobs = {} }, locks = { global = nil }, active_job = nil }
  local changed = pulse.scoped({ close_reason = 'done' })
  local marks = { acquire = 0, release = 0, saves = 0 }
  local ctx = {
    state = state,
    service_scope = fibers.current_scope(),
    service_run_id = 'run-1',
    changed = changed,
    now = fibers.now,
    on_store_error = function() end,
    model = {
      acquire_lock = function(st, job) marks.acquire = marks.acquire + 1; st.locks.global = job.job_id end,
      release_lock = function(st, job) marks.release = marks.release + 1; if st.locks.global == job.job_id then st.locks.global = nil end end,
      set_active_job = function(st, rec) st.active_job = rec end,
      clear_active_job = function(st) st.active_job = nil end,
    },
    store_sync = {
      save_job = function(_, _, _) marks.saves = marks.saves + 1; return true end,
    },
    repo = {},
  }
  return ctx, marks
end

function T.worker_slot_spawns_tracks_and_releases_active_job()
  runfibers.run(function()
    local ctx, marks = fake_ctx()
    local slot = worker_slot_mod.new(ctx)
    local job = { job_id = 'job-1', component = 'mcu' }
    ctx.state.store.jobs[job.job_id] = job

    local ok, err = slot:spawn(job, 'stage', function() end)
    assert(ok, tostring(err))
    assert(slot:current() and slot:current().job_id == 'job-1')
    assert(marks.acquire == 1)
    assert(marks.saves >= 1)

    local joined = fibers.perform(slot:join_op())
    assert(joined.job_id == 'job-1')
    assert(joined.st == 'ok')

    slot:release('job-1')
    assert(slot:current() == nil)
    assert(marks.release == 1)
  end, { timeout = 1.0 })
end

return T
