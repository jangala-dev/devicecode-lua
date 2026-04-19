local job_store = require 'services.update.job_store'

local T = {}

local function new_control_store_cap(backing)
  backing = backing or { namespaces = {} }
  backing.namespaces = backing.namespaces or {}
  return {
    call_control = function(_, method, args)
      local ns = args and args.ns
      local key = args and args.key
      if method == 'get' then
        local value = backing.namespaces[ns] and backing.namespaces[ns][key] or nil
        if value == nil then return { ok = false, reason = 'not_found' } end
        return { ok = true, reason = value }
      elseif method == 'put' then
        backing.namespaces[ns] = backing.namespaces[ns] or {}
        backing.namespaces[ns][key] = args.value
        return { ok = true, reason = { ok = true } }
      elseif method == 'delete' then
        backing.namespaces[ns] = backing.namespaces[ns] or {}
        backing.namespaces[ns][key] = nil
        return { ok = true, reason = { ok = true } }
      elseif method == 'list' then
        local keys = {}
        for k in pairs(backing.namespaces[ns] or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        return { ok = true, reason = { ns = ns, keys = keys } }
      end
      return { ok = false, reason = 'unsupported_method' }
    end,
  }
end

function T.job_store_loads_empty_namespace_and_round_trips_records()
  local backing = {}
  local cap = new_control_store_cap(backing)
  local repo = job_store.open(cap, { namespace = 'update/jobs' })

  local store, err = repo:load_all()
  assert(err == nil)
  assert(type(store) == 'table')
  assert(type(store.jobs) == 'table')
  assert(type(store.order) == 'table')
  assert(next(store.jobs) == nil)
  assert(#store.order == 0)

  local ok, serr = repo:save_job({ job_id = 'j-1', state = 'available', target = 'mcu', created_seq = 10, created_at = 10 })
  assert(ok == true)
  assert(serr == nil)
  local ok2 = repo:save_job({ job_id = 'j-2', state = 'succeeded', target = 'cm5', created_seq = 20, created_at = 20 })
  assert(ok2 == true)

  local loaded, lerr = repo:load_all()
  assert(lerr == nil)
  assert(type(loaded.jobs['j-1']) == 'table')
  assert(loaded.jobs['j-1'].target == 'mcu')
  assert(loaded.jobs['j-2'].state == 'succeeded')
  assert(#loaded.order == 2)
  assert(loaded.order[1] == 'j-1')
  assert(loaded.order[2] == 'j-2')
end

function T.job_store_deletes_job_record()
  local backing = {}
  local cap = new_control_store_cap(backing)
  local repo = job_store.open(cap, { namespace = 'update/jobs' })
  assert(repo:save_job({ job_id = 'j-1', state = 'available', target = 'mcu', created_seq = 10, created_at = 10 }) == true)
  assert(repo:delete_job('j-1') == true)

  local loaded = assert(repo:load_all())
  assert(next(loaded.jobs) == nil)
  assert(#loaded.order == 0)
end


function T.job_store_orders_by_created_seq_when_present()
  local backing = {}
  local cap = new_control_store_cap(backing)
  local repo = job_store.open(cap, { namespace = 'update/jobs' })

  assert(repo:save_job({ job_id = 'j-1', state = 'available', target = 'mcu', created_seq = 20, created_at = 1 }) == true)
  assert(repo:save_job({ job_id = 'j-2', state = 'available', target = 'mcu', created_seq = 10, created_at = 99 }) == true)

  local loaded = assert(repo:load_all())
  assert(loaded.order[1] == 'j-2')
  assert(loaded.order[2] == 'j-1')
end

return T
