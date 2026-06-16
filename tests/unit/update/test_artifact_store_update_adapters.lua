local fibers    = require 'fibers'
local op        = require 'fibers.op'
local runfibers = require 'tests.support.run_fibers'

local store_bus = require 'services.update.artifacts.store_bus'
local component_backend = require 'services.update.backends.component'

local T = {}

local function assert_eq(a, b, msg)
  if a ~= b then error(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)), 2) end
end

local function assert_true(v, msg)
  if v ~= true then error(msg or ('expected true, got ' .. tostring(v)), 2) end
end

function T.artifact_store_bus_unwraps_hal_reply_envelopes()
  runfibers.run(function()
    local sink = { terminated = 0 }
    function sink:append_op(_) return op.always(true, nil) end
    function sink:commit_op() return op.always({ ref = 'artifact-1' }, nil) end
    function sink:terminate(reason) self.terminated = self.terminated + 1; self.reason = reason; return true, nil end

    local source = { read_count = 0 }
    function source:read_chunk_op() self.read_count = self.read_count + 1; return op.always(nil, nil) end

    local artifact = {}
    function artifact:describe() return { artifact_ref = 'artifact-1', size = 10 } end
    function artifact:open_source_op() return op.always(true, source) end

    local conn = {
      call_op = function(_, topic, payload)
        local method = topic[5]
        if method == 'create-sink' then
          assert_eq(payload.policy, 'prefer_durable')
          return op.always({ ok = true, reason = sink }, nil)
        elseif method == 'open' then
          assert_eq(payload.artifact_ref, 'artifact-1')
          return op.always({ ok = true, reason = artifact }, nil)
        elseif method == 'delete' then
          return op.always({ ok = true, reason = nil }, nil)
        elseif method == 'status' then
          return op.always({ ok = true, reason = { available = true } }, nil)
        end
        return op.always({ ok = false, reason = 'bad method' }, nil)
      end,
    }

    local store = store_bus.new(conn)
    local got_sink, sink_err = fibers.perform(store:create_sink_op({ meta = { component = 'mcu' }, policy = 'prefer_durable' }))
    assert_eq(got_sink, sink, tostring(sink_err))

    local got_source, source_err = fibers.perform(store:open_source_op('artifact-1'))
    assert_eq(got_source, source, tostring(source_err))

    local ok_delete, del_err = fibers.perform(store:delete_op('artifact-1'))
    assert_true(ok_delete, tostring(del_err))

    local status, st_err = fibers.perform(store:status_op())
    assert_true(status and status.available, tostring(st_err))
  end)
end

function T.component_backend_stage_op_runs_preflight_prepare_and_stage()
  runfibers.run(function()
    local source = {}
    function source:read_chunk_op() return op.always(nil, nil) end

    local artifact = {}
    function artifact:describe()
      return {
        artifact_ref = 'artifact-1',
        size = 12,
        digest_alg = 'xxhash32',
        digest = 'abcd',
        meta = { image_id = 'img-new', format = 'dcmcu-v1' },
      }
    end
    function artifact:open_source_op()
      -- Exercise the direct source,err adapter shape as well as the HAL true,source shape.
      return op.always(source, nil)
    end

    local artifact_store = {
      open_op = function(_, ref)
        assert_eq(ref, 'artifact-1')
        return op.always(artifact, nil)
      end,
      open_source_op = function(_, ref)
        assert_eq(ref, 'artifact-1')
        return op.always(source, nil)
      end,
    }

    local seen_payload
    local seen_prepare
    local conn = {
      call_op = function(_, topic, payload)
        assert_eq(topic[1], 'cap')
        assert_eq(topic[2], 'component')
        assert_eq(topic[4], 'rpc')
        if topic[5] == 'prepare-update' then
          seen_prepare = payload
          assert_eq(payload.target, 'mcu')
          return op.always({ ok = true }, nil)
        end
        if topic[5] == 'stage-update' then
          seen_payload = payload
          return op.always({ ok = true, public_status = 'succeeded', value = { transferred = true } }, nil)
        end
        return op.always({ ok = true }, nil)
      end,
    }

    local backend = component_backend.new({ conn = conn, artifact_store = artifact_store, component = 'mcu' })
    local job = { job_id = 'job-1', component = 'mcu', artifact_ref = 'artifact-1', expected_image_id = 'img-new', metadata = { format = 'dcmcu-v1' } }

    local staged, serr = fibers.perform(backend:stage_op(job, {}))
    assert_eq(type(staged), 'table', tostring(serr))
    assert_true(staged.staged)
    assert_eq(seen_prepare.target, 'mcu')
    assert_eq(staged.preflight.size, 12)
    assert_eq(staged.transfer.size, 12)
    assert_eq(seen_payload.source, source)
    assert_eq(seen_payload.size, 12)
    assert_eq(seen_payload.digest, 'abcd')
  end)
end

return T
