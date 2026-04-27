local runfibers    = require 'tests.support.run_fibers'
local store_mod    = require 'services.hal.drivers.artifact_store'
local blob_source  = require 'shared.blob_source'
local file         = require 'fibers.io.file'
local exec         = require 'fibers.io.exec'
local fibers       = require 'fibers'

local T = {}

local function rmtree(path)
  local cmd = exec.command('rm', '-rf', path)
  fibers.perform(cmd:run_op())
end

function T.artifact_store_driver_imports_source_opens_and_deletes_transient_artefact()
  runfibers.run(function()
    local base = ('/tmp/devicecode-artifact-store-%d'):format(math.random(1000000))
    local transient_root = base .. '/transient'
    local durable_root = base .. '/durable'
    rmtree(base)
    local store = assert(store_mod.new({ transient_root = transient_root, durable_root = durable_root, durable_enabled = false }))

    local artefact = assert(store:import_source(blob_source.from_string('hello'), { kind = 'update', target = 'mcu' }, { policy = 'transient_only' }))
    local rec = artefact:describe()
    assert(rec.durability == 'transient')
    assert(rec.state == 'ready')
    assert(rec.size == 5)
    assert(type(rec.checksum) == 'string')

    local opened = assert(store:open(artefact:ref()))
    assert(opened:ref() == artefact:ref())
    local src = opened:open_source()
    assert((assert(src:read_chunk(0, 99))) == 'hello')

    local resolved = assert(store:resolve_local(artefact:ref()))
    assert(type(resolved.path) == 'string')

    assert(store:delete(artefact:ref()) == true)
    local missing, err = store:open(artefact:ref())
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
    local art = assert(store:import_source(blob_source.from_string('a'), { kind = 'update' }, { policy = 'prefer_durable' }))
    assert(art:describe().durability == 'transient')
    local none, err = store:create_sink({ kind = 'update' }, { policy = 'require_durable' })
    assert(none == nil)
    assert(err == 'durable_disabled')

    local store2 = assert(store_mod.new({ transient_root = transient_root, durable_root = durable_root, durable_enabled = true }))
    local art2 = assert(store2:import_source(blob_source.from_string('b'), { kind = 'update' }, { policy = 'require_durable' }))
    assert(art2:describe().durability == 'durable')

    rmtree(base)
  end, { timeout = 3.0 })
end

function T.artifact_store_driver_imports_path_into_transient_store_when_durable_is_disabled()
  runfibers.run(function()
    local base = ('/tmp/devicecode-artifact-store-%d'):format(math.random(1000000))
    local transient_root = base .. '/transient'
    local durable_root = base .. '/durable'
    local import_root = base .. '/incoming'
    rmtree(base)
    assert(file.mkdir_p(import_root))

    local f = assert(file.open(import_root .. '/fw.bin', 'w'))
    assert(f:write('firmware-bytes'))
    assert(f:close())

    local store = assert(store_mod.new({
      transient_root = transient_root,
      durable_root = durable_root,
      durable_enabled = false,
    }))

    local artefact = assert(store:import_path(import_root .. '/fw.bin', {
      kind = 'firmware',
      target = 'cm5',
    }, {
      policy = 'prefer_durable',
    }))

    local rec = artefact:describe()
    assert(rec.durability == 'transient')
    assert(rec.state == 'ready')
    local resolved = assert(store:resolve_local(artefact:ref()))
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
    local sink, err = store:create_sink({ kind = 'firmware', target = 'cm5' }, { policy = 'require_durable' })
    assert(sink == nil)
    assert(err == 'durable_disabled')

    local status = store:status()
    assert(status.transient_root == transient_root)
    assert(status.durable_root == durable_root)

    rmtree(base)
  end, { timeout = 3.0 })
end

return T
