local fibers = require 'fibers'
local op     = require 'fibers.op'
local store_mod = require 'services.update.job_store_cap'
local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
function tests.test_memory_store_exposes_operation_shaped_api()
  fibers.run(function ()
    local store = store_mod.memory()
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
    local store = store_mod.memory(); local job = { job_id='j1', component='cm5', nested={a=1} }
    assert_true(fibers.perform(store:save_job_op(job))); job.nested.a = 99
    local loaded = assert(fibers.perform(store:load_all_op()))
    assert_eq(loaded.jobs.j1.nested.a, 1)
  end)
end
function tests.test_control_store_adapter_round_trips_jobs()
  fibers.run(function ()
    local control_store = require 'services.update.job_store_control_store'
    local backing = {}
    local calls = {}
    local conn = {
      call_op = function (_, topic, payload)
        calls[#calls + 1] = { topic = topic, payload = payload }
        local method = topic[5]
        if method == 'list' then
          local keys = {}
          local prefix = payload.prefix or ''
          for k in pairs(backing) do if k:sub(1, #prefix) == prefix then keys[#keys + 1] = k end end
          table.sort(keys)
          return op.always(keys, nil)
        elseif method == 'put' then
          backing[payload.key] = payload.data
          return op.always(true, nil)
        elseif method == 'get' then
          if backing[payload.key] == nil then return op.always(nil, 'not found') end
          return op.always(backing[payload.key], nil)
        elseif method == 'delete' then
          backing[payload.key] = nil
          return op.always(true, nil)
        end
        return op.always(nil, 'unexpected method')
      end,
    }
    local store = store_mod.wrap(control_store.new(conn, { id = 'update', prefix = 'update-job-' }))
    assert_true(fibers.perform(store:save_job_op({ job_id='j/1', component='mcu', state='created', nested={a=1} })))
    local loaded = assert(fibers.perform(store:load_all_op()))
    assert_eq(loaded.jobs['j/1'].component, 'mcu')
    assert_true(fibers.perform(store:delete_job_op('j/1')))
    loaded = assert(fibers.perform(store:load_all_op()))
    assert_eq(loaded.jobs['j/1'], nil)
    assert_eq(calls[1].topic[1], 'cap')
    assert_eq(calls[1].topic[2], 'control-store')
    assert_eq(calls[1].topic[3], 'update')
  end)
end

function tests.test_control_store_adapter_unwraps_hal_replies()
  fibers.run(function ()
    local control_store = require 'services.update.job_store_control_store'
    local reply_mt = {}
    local backing = {}
    local conn = {
      call_op = function (_, topic, payload)
        local method = topic[5]
        if method == 'list' then
          local keys = {}
          for k in pairs(backing) do keys[#keys + 1] = k end
          table.sort(keys)
          return op.always(setmetatable({ ok = true, reason = keys }, reply_mt), nil)
        elseif method == 'put' then
          backing[payload.key] = payload.data
          return op.always(setmetatable({ ok = true, reason = true }, reply_mt), nil)
        elseif method == 'get' then
          return op.always(setmetatable({ ok = true, reason = backing[payload.key] }, reply_mt), nil)
        end
        return op.always(setmetatable({ ok = false, reason = 'unexpected' }, reply_mt), nil)
      end,
    }
    local store = store_mod.wrap(control_store.new(conn))
    assert_true(fibers.perform(store:save_job_op({ job_id='j1', component='mcu', state='created' })))
    local loaded = assert(fibers.perform(store:load_all_op()))
    assert_eq(loaded.jobs.j1.component, 'mcu')
  end)
end

return tests
