local job_store = require 'services.update.job_store'

local T = {}

local function new_fs_cap(backing)
  return {
    call_control = function(_, method, args)
      if method == 'read' then
        local filename = args.filename
        local data = backing[filename]
        if data == nil then
          return { ok = false, reason = 'ENOENT' }
        end
        return { ok = true, reason = data }
      elseif method == 'write' then
        backing[args.filename] = args.data
        return { ok = true, reason = '' }
      end
      return { ok = false, reason = 'unsupported_method' }
    end,
  }
end

function T.job_store_loads_missing_file_as_empty_store_and_round_trips_save()
  local backing = {}
  local fs_cap = new_fs_cap(backing)

  local store, err = job_store.load(fs_cap, 'jobs.json')
  assert(err == nil)
  assert(type(store) == 'table')
  assert(type(store.jobs) == 'table')
  assert(type(store.order) == 'table')
  assert(next(store.jobs) == nil)
  assert(#store.order == 0)

  store.jobs['j-1'] = { job_id = 'j-1', state = 'available', target = 'mcu' }
  store.order[1] = 'j-1'
  local ok, serr = job_store.save(fs_cap, 'jobs.json', store)
  assert(ok == true)
  assert(serr == nil)

  local loaded, lerr = job_store.load(fs_cap, 'jobs.json')
  assert(lerr == nil)
  assert(type(loaded.jobs['j-1']) == 'table')
  assert(loaded.jobs['j-1'].target == 'mcu')
  assert(loaded.jobs['j-1'].state == 'available')
  assert(loaded.order[1] == 'j-1')
end

return T
