-- tests/unit/update/test_device_component_backend.lua

local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'

local backend_mod = require 'services.update.backends.device_component'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

function tests.test_stage_delegates_to_device_component_action()
	fibers.run(function ()
		local captured_topic
		local captured_payload
		local conn = {
			call_op = function (_, topic, payload, opts)
				captured_topic = topic
				captured_payload = payload
				assert_eq(opts.timeout, 900.0)
				return op.always({ ok = true, staged = true }, nil)
			end,
		}
		local backend = backend_mod.new({ conn = conn })
		local result, err = fibers.perform(backend:stage_op({
			job_id = 'job-1',
			component = 'mcu',
			artifact_ref = 'artifact-1',
			metadata = { transfer_chunk_raw = 4096 },
		}, {}))

		assert_not_nil(result, err)
		assert_eq(table.concat(captured_topic, '/'), 'cap/component/mcu/rpc/stage-update')
		assert_eq(captured_payload.artifact_ref, 'artifact-1')
		assert_eq(captured_payload.metadata.transfer_chunk_raw, 4096)
	end)
end

function tests.test_stage_retries_transient_transfer_session_failure()
	fibers.run(function ()
		local calls = 0
		local logged = {}
		local conn = {
			call_op = function ()
				calls = calls + 1
				if calls == 1 then
					return op.always(nil, 'transfer_sender_frame_feed_closed')
				end
				return op.always({ ok = true, staged = true }, nil)
			end,
		}
		local backend = backend_mod.new({
			conn = conn,
			stage_retry_delay_s = 0.001,
			log = function (_level, fields) logged[#logged + 1] = fields end,
		})
		local result, err = fibers.perform(backend:stage_op({
			job_id = 'job-retry',
			component = 'mcu',
			artifact_ref = 'artifact-1',
		}, {}))

		assert_not_nil(result, err)
		assert_eq(calls, 2)
		assert_eq(logged[#logged].what, 'update_device_backend_call_ok')
	end)
end

function tests.test_stage_does_not_retry_signature_failures()
	fibers.run(function ()
		local calls = 0
		local conn = {
			call_op = function ()
				calls = calls + 1
				return op.always(nil, 'imagev1: unknown_key')
			end,
		}
		local backend = backend_mod.new({
			conn = conn,
			stage_retry_delay_s = 0.001,
		})
		local result, err = fibers.perform(backend:stage_op({
			job_id = 'job-sig',
			component = 'mcu',
			artifact_ref = 'artifact-1',
		}, {}))

		assert_eq(result, nil)
		assert_eq(err, 'imagev1: unknown_key')
		assert_eq(calls, 1)
	end)
end

function tests.test_commit_can_use_explicit_compat_image_id_for_bootstrap()
	fibers.run(function ()
		local captured_topic
		local captured_payload
		local logged = {}
		local conn = {
			call_op = function (_, topic, payload, opts)
				captured_topic = topic
				captured_payload = payload
				assert_eq(opts.timeout, 60.0)
				return op.always({ ok = true, accepted = true }, nil)
			end,
		}
		local backend = backend_mod.new({
			conn = conn,
			commit_settle_s = 0,
			log = function (_level, fields) logged[#logged + 1] = fields end,
		})
		local result, err = fibers.perform(backend:commit_op({
			job_id = 'job-1',
			component = 'mcu',
			expected_image_id = 'mcu-dev-13.0',
			metadata = {
				image_id = 'mcu-dev-13.0',
				compat_commit_image_id = 'img-dev',
			},
		}, {}))

		assert_not_nil(result, err)
		assert_eq(table.concat(captured_topic, '/'), 'cap/component/mcu/rpc/commit-update')
		assert_eq(captured_payload.expected_image_id, 'img-dev')
		assert_eq(captured_payload.metadata.image_id, 'mcu-dev-13.0')
		assert_eq(captured_payload.metadata.original_expected_image_id, 'mcu-dev-13.0')
		assert_eq(captured_payload.metadata.compat_commit_expected_image_id, 'img-dev')
		assert_eq(logged[1].what, 'update_device_backend_explicit_compat_commit_image_id')
	end)
end

function tests.test_commit_can_use_observed_legacy_streamed_identity()
	fibers.run(function ()
		local captured_payload
		local conn = {
			call_op = function (_, _topic, payload)
				captured_payload = payload
				return op.always({ ok = true, accepted = true }, nil)
			end,
		}
		local backend = backend_mod.new({ conn = conn, commit_settle_s = 0 })
		local result, err = fibers.perform(backend:commit_op({
			job_id = 'job-1',
			component = 'mcu',
			expected_image_id = 'mcu-dev-13.0',
			metadata = { image_id = 'mcu-dev-13.0' },
		}, {
			component_state = {
				software = { image_id = 'img-dev' },
				updater = {
					state = 'staged',
					pending_image_id = 'mcu-dev-13.0',
					staged_image_id = 'img-dev',
				},
			},
		}))

		assert_not_nil(result, err)
		assert_eq(captured_payload.expected_image_id, 'img-dev')
		assert_eq(captured_payload.metadata.original_expected_image_id, 'mcu-dev-13.0')
	end)
end

function tests.test_commit_keeps_expected_image_without_compat_signal()
	fibers.run(function ()
		local captured_payload
		local conn = {
			call_op = function (_, _topic, payload)
				captured_payload = payload
				return op.always({ ok = true, accepted = true }, nil)
			end,
		}
		local backend = backend_mod.new({ conn = conn, commit_settle_s = 0 })
		local result, err = fibers.perform(backend:commit_op({
			job_id = 'job-1',
			component = 'mcu',
			expected_image_id = 'mcu-dev-13.0',
			metadata = { image_id = 'mcu-dev-13.0' },
		}, {}))

		assert_not_nil(result, err)
		assert_eq(captured_payload.expected_image_id, 'mcu-dev-13.0')
		assert_eq(captured_payload.metadata.original_expected_image_id, nil)
	end)
end

function tests.test_commit_settle_delays_component_call()
	fibers.run(function (scope)
		local calls = 0
		local done = false
		local done_err
		local conn = {
			call_op = function ()
				calls = calls + 1
				return op.always({ ok = true, accepted = true }, nil)
			end,
		}
		local backend = backend_mod.new({ conn = conn, commit_settle_s = 0.02 })

		local ok, spawn_err = scope:spawn(function ()
			local result, err = fibers.perform(backend:commit_op({
				job_id = 'job-1',
				component = 'mcu',
			}, {}))
			done_err = err
			done = result ~= nil
		end)
		assert_eq(ok, true, spawn_err)

		fibers.perform(sleep.sleep_op(0.005))
		assert_eq(calls, 0)
		assert_eq(done, false)

		fibers.perform(sleep.sleep_op(0.05))
		assert_eq(calls, 1)
		assert_eq(done, true, done_err)
	end)
end

function tests.test_reconcile_completes_successfully_by_default()
	local backend = backend_mod.new()
	local result = backend:evaluate_reconcile({
		job_id = 'job-1',
		component = 'mcu',
	}, {
		components = {
			mcu = { software = { version = '1' } },
		},
	}, {})

	assert_eq(result.done, true)
	assert_eq(result.ok, true)
	assert_eq(result.tag, 'reconciled_success')
	assert_eq(result.result.observed.software.version, '1')
end

function tests.test_reconcile_waits_until_expected_image_matches()
	local backend = backend_mod.new()
	local result = backend:evaluate_reconcile({
		job_id = 'job-1',
		component = 'mcu',
		expected_image_id = 'image-new',
		pre_commit_boot_id = 'boot-old',
		metadata = { require_boot_change = true },
	}, {
		components = {
			mcu = {
				software = {
					image_id = 'image-old',
					version = '1',
					build = 'build-old',
					boot_id = 'boot-new',
				},
				updater = { state = 'running' },
			},
		},
	}, {})

	assert_eq(result.done, false)
	assert_eq(result.result.expected_image_id, 'image-new')
	assert_eq(result.result.image_id, 'image-old')
	assert_eq(result.result.boot_changed, true)
	assert_eq(result.result.phase, 'running')
end

function tests.test_reconcile_succeeds_when_expected_image_matches()
	local backend = backend_mod.new()
	local result = backend:evaluate_reconcile({
		job_id = 'job-1',
		component = 'mcu',
		expected_image_id = 'image-new',
		pre_commit_boot_id = 'boot-old',
		metadata = { require_boot_change = true },
	}, {
		components = {
			mcu = {
				software = {
					image_id = 'image-new',
					boot_id = 'boot-new',
				},
				updater = { state = 'running' },
			},
		},
	}, {})

	assert_eq(result.done, true)
	assert_eq(result.ok, true)
	assert_eq(result.tag, 'reconciled_success')
	assert_eq(result.result.expected_image_id, 'image-new')
	assert_eq(result.result.image_id, 'image-new')
	assert_eq(result.result.boot_changed, true)
	assert_eq(result.result.phase, 'running')
end

function tests.test_reconcile_accepts_active_observer_by_id_snapshot()
	local backend = backend_mod.new()
	local result = backend:evaluate_reconcile({
		job_id = 'job-1',
		component = 'mcu',
		expected_image_id = 'image-new',
	}, {
		by_id = {
			mcu = {
				state = {
					software = { image_id = 'image-new' },
					updater = { state = 'running' },
				},
			},
		},
	}, {})

	assert_eq(result.done, true)
	assert_eq(result.ok, true)
	assert_eq(result.result.image_id, 'image-new')
end

return tests
