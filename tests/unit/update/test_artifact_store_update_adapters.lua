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

local function fake_observer(software, overrides)
  local state = {
    software = software,
    updater = { state = 'running' },
    health = { state = 'ok' },
    actions = { ['prepare-update'] = true, ['stage-update'] = true, ['commit-update'] = true },
  }
  for k, v in pairs(overrides or {}) do state[k] = v end
  return {
    snapshot = function()
      return {
        components = {
          mcu = {
            state = state,
          },
        },
      }
    end,
  }
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
    local got_sink, sink_err = fibers.perform(store:create_sink_op({
      meta = { component = 'mcu' },
      policy = 'prefer_durable',
    }))
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
        error('component backend must not open artifact source before Device stage action: ' .. tostring(ref), 0)
      end,
    }

    local seen_payload
    local seen_prepare
    local seen_stage_opts
    local conn = {
      call_op = function(_, topic, payload, opts)
        assert_eq(topic[1], 'cap')
        assert_eq(topic[2], 'component')
        assert_eq(topic[4], 'rpc')
        if topic[5] == 'prepare-update' then
          seen_prepare = payload
          assert_eq(payload.target, 'mcu')
          return op.always({ ok = true, max_chunk_size = 512 }, nil)
        end
        if topic[5] == 'stage-update' then
          seen_payload = payload
          seen_stage_opts = opts
          return op.always({ ok = true, public_status = 'succeeded', value = { transferred = true } }, nil)
        end
        return op.always({ ok = true }, nil)
      end,
    }

    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0', boot_id = 'boot-old' }),
    })
    local job = {
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
      metadata = { image_id = 'img-new', transfer_chunk_raw = 1024 },
    }

    local staged, serr = fibers.perform(backend:stage_op(job, {}))
    assert_eq(type(staged), 'table', tostring(serr))
    assert_true(staged.staged)
    assert_eq(seen_prepare.target, 'mcu')
    assert_eq(staged.preflight.size, 12)
    assert_eq(staged.transfer.size, 12)
    assert_eq(seen_payload.source, nil)
    assert_eq(seen_payload.artifact_ref, 'artifact-1')
    assert_eq(seen_payload.size, 12)
    assert_eq(seen_payload.digest, 'abcd')
    assert_eq(seen_payload.chunk_size, 1024)
    assert_eq(seen_stage_opts.timeout, false)
  end)
end

function T.component_backend_commit_op_requires_explicit_acceptance()
  runfibers.run(function()
    local replies = {
      accepted = {
        reply = { accepted = true },
        ok = true,
      },
      wrapped = {
        reply = { ok = true, public_status = 'succeeded', value = { accepted = true } },
        ok = true,
      },
      ok_false = {
        reply = { ok = false, reason = 'commit_refused' },
        err = 'commit_refused',
      },
      failed_public_status = {
        reply = { ok = true, public_status = 'failed', err = 'commit_failed' },
        err = 'commit_failed',
      },
      accepted_false = {
        reply = { ok = true, public_status = 'succeeded', value = { accepted = false, reason = 'busy' } },
        err = 'busy',
      },
      missing_accepted = {
        reply = { ok = true, public_status = 'succeeded', value = { state = 'queued' } },
        err = 'component_commit_acceptance_missing',
      },
    }

    for _, name in ipairs({
      'accepted',
      'wrapped',
      'ok_false',
      'failed_public_status',
      'accepted_false',
      'missing_accepted',
    }) do
      local case = replies[name]
      local conn = {
        call_op = function(_, topic)
          assert_eq(topic[5], 'commit-update')
          return op.always(case.reply, nil)
        end,
      }
      local backend = component_backend.new({ conn = conn, component = 'mcu' })
      local got, err = fibers.perform(backend:commit_op({
        job_id = 'job-commit',
        component = 'mcu',
        metadata = { image_id = 'img-new' },
      }, {}))
      if case.ok then
        assert_eq(type(got), 'table', tostring(err))
        assert_true(got.accepted)
      else
        assert_eq(got, nil)
        assert_eq(err, case.err, name)
      end
    end
  end)
end

function T.component_backend_stage_op_clamps_metadata_chunk_size_to_prepare_max()
  runfibers.run(function()
    local source = {}
    function source:read_chunk_op() return op.always(nil, nil) end
    local artifact = {}
    function artifact:describe()
      return { artifact_ref = 'artifact-1', size = 12, digest = 'abcd', meta = { image_id = 'img-new' } }
    end
    local artifact_store = {
      open_op = function() return op.always(artifact, nil) end,
      open_source_op = function() return op.always(source, nil) end,
    }
    local seen_payload
    local conn = {
      call_op = function(_, topic, payload)
        if topic[5] == 'prepare-update' then
          return op.always({ ok = true, max_chunk_size = 512 }, nil)
        end
        if topic[5] == 'stage-update' then
          seen_payload = payload
          return op.always({ ok = true, public_status = 'succeeded' }, nil)
        end
        return op.always({ ok = true }, nil)
      end,
    }
    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0', boot_id = 'boot-old' }),
    })

    local staged, serr = fibers.perform(backend:stage_op({
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
      metadata = { image_id = 'img-new', chunk_size = 2048 },
    }, {}))
    assert_eq(type(staged), 'table', tostring(serr))
    assert_eq(seen_payload.chunk_size, 512)
  end)
end

function T.component_backend_stage_op_clamps_default_chunk_size_to_prepare_max()
  runfibers.run(function()
    local source = {}
    function source:read_chunk_op() return op.always(nil, nil) end
    local artifact = {}
    function artifact:describe()
      return { artifact_ref = 'artifact-1', size = 12, digest = 'abcd', meta = { image_id = 'img-new' } }
    end
    local artifact_store = {
      open_op = function() return op.always(artifact, nil) end,
      open_source_op = function() return op.always(source, nil) end,
    }
    local seen_payload
    local conn = {
      call_op = function(_, topic, payload)
        if topic[5] == 'prepare-update' then
          return op.always({ ok = true, max_chunk_size = 512 }, nil)
        end
        if topic[5] == 'stage-update' then
          seen_payload = payload
          return op.always({ ok = true, public_status = 'succeeded' }, nil)
        end
        return op.always({ ok = true }, nil)
      end,
    }
    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0', boot_id = 'boot-old' }),
      chunk_size = 2048,
    })

    local staged, serr = fibers.perform(backend:stage_op({
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
      metadata = { image_id = 'img-new' },
    }, {}))
    assert_eq(type(staged), 'table', tostring(serr))
    assert_eq(seen_payload.chunk_size, 512)
  end)
end

function T.component_backend_stage_op_keeps_configured_chunk_when_prepare_max_absent()
  runfibers.run(function()
    local source = {}
    function source:read_chunk_op() return op.always(nil, nil) end
    local artifact = {}
    function artifact:describe()
      return { artifact_ref = 'artifact-1', size = 12, digest = 'abcd', meta = { image_id = 'img-new' } }
    end
    local artifact_store = {
      open_op = function() return op.always(artifact, nil) end,
      open_source_op = function() return op.always(source, nil) end,
    }
    local seen_payload
    local conn = {
      call_op = function(_, topic, payload)
        if topic[5] == 'prepare-update' then
          return op.always({ ok = true }, nil)
        end
        if topic[5] == 'stage-update' then
          seen_payload = payload
          return op.always({ ok = true, public_status = 'succeeded' }, nil)
        end
        return op.always({ ok = true }, nil)
      end,
    }
    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0', boot_id = 'boot-old' }),
      chunk_size = 2048,
    })

    local staged, serr = fibers.perform(backend:stage_op({
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
      metadata = { image_id = 'img-new' },
    }, {}))
    assert_eq(type(staged), 'table', tostring(serr))
    assert_eq(seen_payload.chunk_size, 2048)
  end)
end

function T.component_backend_stage_op_requires_component_boot_id_before_prepare()
  runfibers.run(function()
    local calls = {}
    local artifact_store = {
      open_op = function()
        calls.open = true
        return op.always({}, nil)
      end,
      open_source_op = function()
        calls.source = true
        return op.always({}, nil)
      end,
    }
    local conn = {
      call_op = function(_, topic)
        calls[topic[5]] = true
        return op.always({ ok = true }, nil)
      end,
    }

    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0' }),
    })
    local job = {
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
      metadata = { image_id = 'img-new' },
    }

    local staged, serr = fibers.perform(backend:stage_op(job, {}))
    assert_eq(staged, nil)
    assert_eq(serr, 'mcu_control_plane_not_ready:software_boot_id_unavailable')
    assert_eq(calls.open, nil, 'artifact should not open before boot_id readiness')
    assert_eq(calls['prepare-update'], nil, 'prepare-update should not be called before boot_id readiness')
    assert_eq(calls['stage-update'], nil, 'stage-update should not be called before boot_id readiness')
  end)
end

function T.component_backend_stage_op_requires_mcu_critical_facts_before_artifact_open()
  runfibers.run(function()
    local calls = {}
    local artifact_store = {
      open_op = function() calls.open = true; return op.always({}, nil) end,
      open_source_op = function() calls.source = true; return op.always({}, nil) end,
    }
    local conn = {
      call_op = function(_, topic)
        calls[topic[5]] = true
        return op.always({ ok = true }, nil)
      end,
    }
    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0', boot_id = 'boot-old' }, {
        updater = {},
        health = {},
      }),
    })

    local staged, serr = fibers.perform(backend:stage_op({
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
    }, {}))
    assert_eq(staged, nil)
    assert_eq(serr, 'mcu_control_plane_not_ready:missing_critical_facts:updater,health')
    assert_eq(calls.open, nil, 'artifact should not open before critical state readiness')
    assert_eq(calls['prepare-update'], nil, 'prepare-update should not be called before critical state readiness')
  end)
end

function T.component_backend_stage_op_requires_prepare_route_before_artifact_open()
  runfibers.run(function()
    local calls = {}
    local artifact_store = {
      open_op = function() calls.open = true; return op.always({}, nil) end,
      open_source_op = function() calls.source = true; return op.always({}, nil) end,
    }
    local conn = {
      call_op = function(_, topic)
        calls[topic[5]] = true
        return op.always({ ok = true }, nil)
      end,
    }
    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0', boot_id = 'boot-old' }, {
        actions = { ['stage-update'] = true, ['commit-update'] = true },
      }),
    })

    local staged, serr = fibers.perform(backend:stage_op({
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
    }, {}))
    assert_eq(staged, nil)
    assert_eq(serr, 'mcu_control_plane_not_ready:prepare_route_missing')
    assert_eq(calls.open, nil, 'artifact should not open before prepare route readiness')
    assert_eq(calls['prepare-update'], nil, 'prepare-update should not be called before prepare route readiness')
  end)
end

function T.component_backend_stage_op_admits_real_component_projection_shape()
  runfibers.run(function()
    local opened = false
    local artifact = {}
    function artifact:describe()
      return { artifact_ref = 'artifact-1', size = 12, digest = 'abcd', meta = { image_id = 'img-new' } }
    end
    local artifact_store = {
      open_op = function(_, ref)
        opened = true
        assert_eq(ref, 'artifact-1')
        return op.always(artifact, nil)
      end,
    }
    local conn = {
      call_op = function(_, topic)
        if topic[5] == 'prepare-update' then
          return op.always({ ok = true, max_chunk_size = 512 }, nil)
        end
        if topic[5] == 'stage-update' then
          return op.always({ ok = true, public_status = 'succeeded', value = { transferred = true } }, nil)
        end
        return op.always({ ok = true }, nil)
      end,
    }
    local observer = {
      snapshot = function()
        return {
          components = {
            mcu = {
              kind = 'device.component',
              component = 'mcu',
              software = { image_id = 'img-old', version = '1.0', boot_id = 'boot-old' },
              updater = { state = 'ready' },
              health = 'ok',
              actions = { ['prepare-update'] = true, ['stage-update'] = true },
              source = { kind = 'member', member = 'mcu' },
            },
          },
        }
      end,
    }
    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = observer,
    })

    local staged, serr = fibers.perform(backend:stage_op({
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
      metadata = { image_id = 'img-new' },
    }, {}))

    assert_eq(type(staged), 'table', tostring(serr))
    assert_true(opened, 'artifact metadata should open after real-shape admission passes')
  end)
end

function T.component_backend_stage_op_rejects_source_reason_before_artifact_open()
  runfibers.run(function()
    local calls = {}
    local artifact_store = {
      open_op = function() calls.open = true; return op.always({}, nil) end,
      open_source_op = function() calls.source = true; return op.always({}, nil) end,
    }
    local conn = {
      call_op = function(_, topic)
        calls[topic[5]] = true
        return op.always({ ok = true }, nil)
      end,
    }
    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0', boot_id = 'boot-old' }, {
        source = { reason = 'liveness_timeout' },
      }),
    })

    local staged, serr = fibers.perform(backend:stage_op({
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
    }, {}))
    assert_eq(staged, nil)
    assert_eq(serr, 'mcu_control_plane_not_ready:liveness_timeout')
    assert_eq(calls.open, nil, 'artifact should not open before source readiness')
    assert_eq(calls['prepare-update'], nil, 'prepare-update should not be called before source readiness')
  end)
end

function T.component_backend_stage_op_labels_prepare_timeout()
  runfibers.run(function()
    local artifact = {}
    function artifact:describe()
      return { artifact_ref = 'artifact-1', size = 12, meta = { image_id = 'img-new' } }
    end

    local artifact_store = {
      open_op = function()
        return op.always(artifact, nil)
      end,
      open_source_op = function()
        error('open_source_op should not run after prepare timeout', 0)
      end,
    }
    local conn = {
      call_op = function(_, topic)
        if topic[5] == 'prepare-update' then
          return op.always(nil, 'timeout')
        end
        return op.always({ ok = true }, nil)
      end,
    }

    local backend = component_backend.new({
      conn = conn,
      artifact_store = artifact_store,
      component = 'mcu',
      observer = fake_observer({ image_id = 'img-old', version = '1.0', boot_id = 'boot-old' }),
    })
    local job = {
      job_id = 'job-1',
      component = 'mcu',
      artifact_ref = 'artifact-1',
      metadata = { image_id = 'img-new' },
    }

    local staged, serr = fibers.perform(backend:stage_op(job, {}))
    assert_eq(staged, nil)
    assert_eq(serr, 'component_prepare_update_failed:timeout')
  end)
end

return T
