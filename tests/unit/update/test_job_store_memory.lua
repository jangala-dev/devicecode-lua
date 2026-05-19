local fibers = require 'fibers'
local store_mod = require 'services.update.job_store_memory'
local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
function tests.test_memory_store_exposes_operation_shaped_api()
  fibers.run(function ()
    local store = store_mod.new()
    assert_true(fibers.perform(store:save_job_op({ job_id='j1', component='cm5', state='created' })))
    local loaded = assert(fibers.perform(store:load_all_op()))
    assert_eq(loaded.jobs.j1.component, 'cm5')
    assert_true(fibers.perform(store:delete_job_op('j1')))
    loaded = assert(fibers.perform(store:load_all_op()))
    assert_eq(loaded.jobs.j1, nil)
  end)
end
function tests.test_store_snapshots_are_copied()
  fibers.run(function ()
    local store = store_mod.new(); local job = { job_id='j1', component='cm5', nested={a=1} }
    assert_true(fibers.perform(store:save_job_op(job))); job.nested.a = 99
    local loaded = assert(fibers.perform(store:load_all_op()))
    assert_eq(loaded.jobs.j1.nested.a, 1)
  end)
end
return tests
