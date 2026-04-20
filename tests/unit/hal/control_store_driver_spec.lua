local runfibers = require 'tests.support.run_fibers'
local store_mod = require 'services.hal.drivers.control_store'
local exec      = require 'fibers.io.exec'
local fibers    = require 'fibers'

local T = {}

local function rmtree(path)
  local cmd = exec.command('rm', '-rf', path)
  fibers.perform(cmd:run_op())
end

function T.control_store_driver_put_get_list_and_delete_records()
  runfibers.run(function()
    local root = ('/tmp/devicecode-control-store-%d'):format(math.random(1000000))
    rmtree(root)
    local store, err = store_mod.new({ root = root, max_record_bytes = 1024 })
    assert(store ~= nil, tostring(err))

    local ok, perr = store:put('update/jobs', 'j-1', { job_id = 'j-1', state = 'available' })
    assert(ok == true)
    assert(perr == '')

    local value, gerr = store:get('update/jobs', 'j-1')
    assert(gerr == '')
    assert(type(value) == 'table')
    assert(value.job_id == 'j-1')

    local keys, lerr = store:list('update/jobs')
    assert(lerr == '')
    assert(#keys == 1 and keys[1] == 'j-1')

    local dok, derr = store:delete('update/jobs', 'j-1')
    assert(dok == true)
    assert(derr == '')

    local missing, merr = store:get('update/jobs', 'j-1')
    assert(missing == nil)
    assert(merr == 'not_found')

    rmtree(root)
  end, { timeout = 3.0 })
end

function T.control_store_driver_rejects_oversized_record()
  runfibers.run(function()
    local root = ('/tmp/devicecode-control-store-%d'):format(math.random(1000000))
    rmtree(root)
    local store = assert(store_mod.new({ root = root, max_record_bytes = 32 }))
    local ok, err = store:put('update/jobs', 'j-big', { payload = string.rep('x', 256) })
    assert(ok == false)
    assert(err == 'record_too_large')
    rmtree(root)
  end, { timeout = 3.0 })
end

function T.control_store_driver_rejects_oversized_record_without_clobbering_existing_record_or_index()
  runfibers.run(function()
    local root = ('/tmp/devicecode-control-store-%d'):format(math.random(1000000))
    rmtree(root)
    local store = assert(store_mod.new({ root = root, max_record_bytes = 96 }))

    local ok1, err1 = store:put('update/jobs', 'j-keep', { job_id = 'j-keep', state = 'available' })
    assert(ok1 == true)
    assert(err1 == '')

    local ok2, err2 = store:put('update/jobs', 'j-keep', { payload = string.rep('x', 512) })
    assert(ok2 == false)
    assert(err2 == 'record_too_large')

    local value, verr = store:get('update/jobs', 'j-keep')
    assert(verr == '')
    assert(type(value) == 'table')
    assert(value.job_id == 'j-keep')
    assert(value.state == 'available')

    local missing, merr = store:get('update/jobs', 'j-big')
    assert(missing == nil)
    assert(merr == 'not_found')

    local keys, lerr = store:list('update/jobs')
    assert(lerr == '')
    assert(#keys == 1 and keys[1] == 'j-keep')

    rmtree(root)
  end, { timeout = 3.0 })
end

return T
