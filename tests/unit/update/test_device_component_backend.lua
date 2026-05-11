-- tests/unit/update/test_device_component_backend.lua

local fibers = require 'fibers'
local op = require 'fibers.op'

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
				assert_eq(opts.timeout, 300.0)
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

return tests
