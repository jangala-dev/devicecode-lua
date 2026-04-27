local runfibers = require 'tests.support.run_fibers'
local op = require 'fibers.op'
local driver_mod = require 'services.hal.drivers.signature_verify_openssl'

local T = {}

local function make_stream(path, sink)
  return {
    filename = function() return path end,
    write = function(_, data) sink.data = (sink.data or '') .. data return #data end,
    flush = function() return true, nil end,
    close = function() sink.closed = true return true, nil end,
  }
end

function T.driver_writes_temp_files_invokes_openssl_and_maps_success()
  runfibers.run(function()
    local sinks = {}
    local idx = 0
    local seen_argv
    local drv = driver_mod.new({
      tmpdir = '/tmp/test-sig',
      file = {
        tmpfile = function()
          idx = idx + 1
          local sink = {}
          sinks[idx] = sink
          return make_stream('/tmp/test-sig/f' .. idx, sink), nil
        end,
      },
      exec = {
        command = function(...)
          seen_argv = { ... }
          return { combined_output_op = function() return op.always('Signature Verified Successfully', 'exited', 0, nil, nil) end }
        end,
      },
    })

    local ok, err = drv:verify_ed25519('PUB', 'MSG', 'SIG')
    assert(ok == true)
    assert(err == nil)
    assert(seen_argv[1] == 'openssl')
    assert(seen_argv[2] == 'pkeyutl')
    assert(seen_argv[3] == '-verify')
    assert(seen_argv[4] == '-pubin')
    assert(seen_argv[5] == '-inkey')
    assert(seen_argv[7] == '-sigfile')
    assert(seen_argv[9] == '-in')
    assert(seen_argv[11] == '-rawin')
    assert(sinks[1].data == 'PUB')
    assert(sinks[2].data == 'MSG')
    assert(sinks[3].data == 'SIG')
    assert(sinks[1].closed == true and sinks[2].closed == true and sinks[3].closed == true)
  end, { timeout = 2.0 })
end

function T.driver_maps_verification_failure_and_exec_failure()
  runfibers.run(function()
    local idx = 0
    local drv = driver_mod.new({
      file = {
        tmpfile = function()
          idx = idx + 1
          return make_stream('/tmp/test-sig/f' .. idx, {}), nil
        end,
      },
      exec = {
        command = function()
          return { combined_output_op = function() return op.always('Signature Verification Failure', 'exited', 1, nil, nil) end }
        end,
      },
    })
    local ok1, err1 = drv:verify_ed25519('PUB', 'MSG', 'SIG')
    assert(ok1 == false)
    assert(err1 == 'signature_verify_failed')

    local drv2 = driver_mod.new({
      file = {
        tmpfile = function()
          idx = idx + 1
          return make_stream('/tmp/test-sig/g' .. idx, {}), nil
        end,
      },
      exec = {
        command = function()
          return { combined_output_op = function() return op.always('bad options', 'exited', 1, nil, nil) end }
        end,
      },
    })
    local ok2, err2 = drv2:verify_ed25519('PUB', 'MSG', 'SIG')
    assert(ok2 == nil)
    assert(tostring(err2):match('^openssl_verify_failed:'))
  end, { timeout = 2.0 })
end

return T
