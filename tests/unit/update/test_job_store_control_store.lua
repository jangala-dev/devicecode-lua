local fibers    = require 'fibers'
local runfibers = require 'tests.support.run_fibers'
local store_mod = require 'services.update.job_store_control_store'

local T = {}

local function fake_conn()
  local data = {}
  local calls = {}
  return {
    calls = calls,
    data = data,
    call_op = function(_, topic, payload)
      calls[#calls + 1] = { topic = topic, payload = payload }
      local method = topic[5]
      if topic[1] ~= 'cap' or topic[2] ~= 'control-store' or topic[3] ~= 'update' or topic[4] ~= 'rpc' then
        return require('fibers.op').always({ ok = false, reason = 'bad_topic' }, nil)
      end
      if method == 'list' then
        local prefix = payload and payload.prefix or ''
        local out = {}
        for k in pairs(data) do
          if prefix == '' or k:sub(1, #prefix) == prefix then out[#out + 1] = k end
        end
        table.sort(out)
        return require('fibers.op').always({ ok = true, reason = out }, nil)
      elseif method == 'get' then
        if data[payload.key] == nil then return require('fibers.op').always({ ok = false, reason = 'not found' }, nil) end
        return require('fibers.op').always({ ok = true, reason = data[payload.key] }, nil)
      elseif method == 'put' then
        data[payload.key] = payload.data
        return require('fibers.op').always({ ok = true, reason = nil }, nil)
      elseif method == 'delete' then
        data[payload.key] = nil
        return require('fibers.op').always({ ok = true, reason = nil }, nil)
      end
      return require('fibers.op').always({ ok = false, reason = 'bad_method' }, nil)
    end,
  }
end

function T.save_load_and_delete_round_trip()
  runfibers.run(function()
    local conn = fake_conn()
    local store = store_mod.new(conn)

    local ok_save, save_err = fibers.perform(store:save_job_op({
      job_id = 'job-1',
      component = 'mcu',
      state = 'created',
      created_seq = 1,
      updated_seq = 1,
      history = {},
    }))
    assert(ok_save == true, tostring(save_err))
    assert(conn.data['update-job-job-1'] ~= nil)

    local snapshot, load_err = fibers.perform(store:load_all_op())
    assert(snapshot ~= nil, tostring(load_err))
    assert(snapshot.jobs['job-1'].component == 'mcu')
    assert(snapshot.order[1] == 'job-1')

    local ok_delete, delete_err = fibers.perform(store:delete_job_op('job-1'))
    assert(ok_delete == true, tostring(delete_err))
    assert(conn.data['update-job-job-1'] == nil)
  end)
end

function T.uses_control_store_update_capability()
  runfibers.run(function()
    local conn = fake_conn()
    local store = store_mod.new(conn)
    local ok_save = fibers.perform(store:save_job_op({ job_id = 'job-2', component = 'mcu' }))
    assert(ok_save == true)
    local t = conn.calls[1].topic
    assert(t[1] == 'cap')
    assert(t[2] == 'control-store')
    assert(t[3] == 'update')
    assert(t[4] == 'rpc')
    assert(t[5] == 'put')
  end)
end

function T.accepts_hal_void_success_replies_for_put_and_delete()
  runfibers.run(function()
    local stored = {}
    local conn = {
      call_op = function(_, topic, payload)
        local method = topic[5]
        if method == 'put' then
          stored[payload.key] = payload.data
          return require('fibers.op').always({ ok = true, reason = nil }, nil)
        elseif method == 'delete' then
          stored[payload.key] = nil
          return require('fibers.op').always({ ok = true, reason = nil }, nil)
        elseif method == 'list' then
          local out = {}
          for key in pairs(stored) do out[#out + 1] = key end
          table.sort(out)
          return require('fibers.op').always({ ok = true, reason = out }, nil)
        elseif method == 'get' then
          return require('fibers.op').always({ ok = true, reason = stored[payload.key] }, nil)
        end
        return require('fibers.op').always({ ok = false, reason = 'bad method' }, nil)
      end,
    }

    local store = store_mod.new(conn)
    local ok_save, save_err = fibers.perform(store:save_job_op({ job_id = 'job-hal', component = 'mcu', state = 'created' }))
    assert(ok_save == true, tostring(save_err))

    local snapshot, load_err = fibers.perform(store:load_all_op())
    assert(snapshot ~= nil, tostring(load_err))
    assert(snapshot.jobs['job-hal'].component == 'mcu')

    local ok_delete, delete_err = fibers.perform(store:delete_job_op('job-hal'))
    assert(ok_delete == true, tostring(delete_err))
  end)
end

function T.load_all_ignores_stale_index_entries()
  runfibers.run(function()
    local data = {
      ['update-job-present'] = require('cjson.safe').encode({
        job_id = 'present',
        component = 'mcu',
        state = 'created',
      }),
    }
    local conn = {
      call_op = function(_, topic, payload)
        local method = topic[5]
        if method == 'list' then
          return require('fibers.op').always({
            ok = true,
            reason = { 'update-job-missing', 'update-job-present' },
          }, nil)
        elseif method == 'get' then
          if data[payload.key] == nil then
            return require('fibers.op').always({ ok = false, reason = 'not found' }, nil)
          end
          return require('fibers.op').always({ ok = true, reason = data[payload.key] }, nil)
        end
        return require('fibers.op').always({ ok = false, reason = 'bad method' }, nil)
      end,
    }

    local store = store_mod.new(conn)
    local snapshot, load_err = fibers.perform(store:load_all_op())
    assert(snapshot ~= nil, tostring(load_err))
    assert(snapshot.jobs.present.component == 'mcu')
    assert(snapshot.jobs.missing == nil)
    assert(#snapshot.order == 1)
    assert(snapshot.order[1] == 'present')
  end)
end

return T
