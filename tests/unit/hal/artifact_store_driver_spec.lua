local runfibers   = require 'tests.support.run_fibers'
local store_mod    = require 'services.hal.drivers.artifact_store'

local T = {}

local function rmtree(path)
  os.execute(('rm -rf %q'):format(path))
end

function T.artifact_store_driver_create_append_finalise_and_delete_transient_artifact()
  runfibers.run(function()
    local base = ('/tmp/devicecode-artifact-store-%d'):format(math.random(1000000))
    local transient_root = base .. '/transient'
    local durable_root = base .. '/durable'
    rmtree(base)
    local store = assert(store_mod.new({ transient_root = transient_root, durable_root = durable_root, durable_enabled = false }))

    local rec = assert(store:create({ kind = 'update', target = 'mcu' }, { policy = 'transient_only' }))
    assert(rec.durability == 'transient')
    assert(rec.state == 'writing')

    local rec2 = assert(store:append(rec.artifact_ref, 'hello'))
    assert(rec2.size == 5)
    local final = assert(store:finalise(rec.artifact_ref))
    assert(final.state == 'ready')
    assert(final.size == 5)
    assert(type(final.checksum) == 'string')

    local resolved = assert(store:resolve_local(rec.artifact_ref))
    assert(type(resolved.path) == 'string')

    assert(store:delete(rec.artifact_ref) == true)
    local missing, err = store:describe(rec.artifact_ref)
    assert(missing == nil)
    assert(err == 'not_found')

    rmtree(base)
  end, { timeout = 3.0 })
end

function T.artifact_store_driver_honours_durability_policy()
  runfibers.run(function()
    local base = ('/tmp/devicecode-artifact-store-%d'):format(math.random(1000000))
    local transient_root = base .. '/transient'
    local durable_root = base .. '/durable'
    rmtree(base)

    local store = assert(store_mod.new({ transient_root = transient_root, durable_root = durable_root, durable_enabled = false }))
    local rec = assert(store:create({ kind = 'update' }, { policy = 'prefer_durable' }))
    assert(rec.durability == 'transient')
    local none, err = store:create({ kind = 'update' }, { policy = 'require_durable' })
    assert(none == nil)
    assert(err == 'durable_disabled')

    local store2 = assert(store_mod.new({ transient_root = transient_root, durable_root = durable_root, durable_enabled = true }))
    local rec2 = assert(store2:create({ kind = 'update' }, { policy = 'require_durable' }))
    assert(rec2.durability == 'durable')

    rmtree(base)
  end, { timeout = 3.0 })
end


function T.artifact_store_driver_imports_into_transient_store_when_durable_is_disabled()
  runfibers.run(function()
    local base = ('/tmp/devicecode-artifact-store-%d'):format(math.random(1000000))
    local transient_root = base .. '/transient'
    local durable_root = base .. '/durable'
    local import_root = base .. '/incoming'
    rmtree(base)
    assert(os.execute(('mkdir -p %q'):format(import_root)) == true or true)

    local f = assert(io.open(import_root .. '/fw.bin', 'wb'))
    assert(f:write('firmware-bytes'))
    assert(f:close())

    local prev = os.getenv('DEVICECODE_IMPORT_ARTIFACT_ROOT')
    assert(os.setenv == nil or true)
    -- Lua has no standard setenv; rely on absolute import path below.

    local store = assert(store_mod.new({
      transient_root = transient_root,
      durable_root = durable_root,
      durable_enabled = false,
    }))

    local rec = assert(store:import_path(import_root .. '/fw.bin', {
      kind = 'firmware',
      target = 'cm5',
    }, {
      policy = 'prefer_durable',
    }))

    assert(rec.durability == 'transient')
    assert(rec.state == 'ready')
    local resolved = assert(store:resolve_local(rec.artifact_ref))
    assert(resolved.durability == 'transient')
    assert(resolved.path:match('^' .. transient_root:gsub('([%%%^%$%(%)%%.%[%]%*%+%-%?])','%%%1')))

    local status = store:status()
    assert(status.durable_enabled == false)
    assert(status.transient_root == transient_root)
    assert(status.durable_root == durable_root)

    rmtree(base)
  end, { timeout = 3.0 })
end

function T.artifact_store_driver_require_durable_rejection_leaves_no_artifact_dirs()
  runfibers.run(function()
    local base = ('/tmp/devicecode-artifact-store-%d'):format(math.random(1000000))
    local transient_root = base .. '/transient'
    local durable_root = base .. '/durable'
    rmtree(base)

    local store = assert(store_mod.new({ transient_root = transient_root, durable_root = durable_root, durable_enabled = false }))
    local rec, err = store:create({ kind = 'firmware', target = 'cm5' }, { policy = 'require_durable' })
    assert(rec == nil)
    assert(err == 'durable_disabled')

    local p = io.popen(('find %q -mindepth 1 -maxdepth 3 -type d 2>/dev/null | wc -l'):format(base))
    local out = p and p:read('*a') or '0'
    if p then p:close() end
    local n = tonumber((out or ''):match('%d+')) or 0
    -- only the transient root may have been created at init time; no per-artifact directories should exist.
    assert(n <= 2)

    rmtree(base)
  end, { timeout = 3.0 })
end

return T
