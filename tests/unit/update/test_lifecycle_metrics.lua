-- tests/unit/update/test_lifecycle_metrics.lua

local metrics = require 'services.update.lifecycle_metrics'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end

function tests.test_safe_token_replaces_namespace_unsafe_characters()
	assert_eq(metrics.safe_token('job/mcu.1 ready'), 'job_mcu_1_ready')
	assert_eq(metrics.safe_token('job-1_ok'), 'job-1_ok')
	assert_eq(metrics.safe_token('///'), 'unknown')
end

function tests.test_emit_publishes_component_lifecycle_payload()
	local seen
	local svc = {
		obs_metric = function (_, name, payload)
			seen = { name = name, payload = payload }
		end,
	}

	local ok, err = metrics.emit(nil, svc, {
		job_id = 'job/mcu.1',
		component = 'mcu',
		state = 'ready',
		error = nil,
	}, 'started', { source = 'device_component_fact' })

	assert_eq(ok, true, err)
	assert_not_nil(seen, 'expected obs_metric call')
	assert_eq(seen.name, 'component_update_lifecycle')
	assert_eq(seen.payload.value, 'started')
	assert_eq(table.concat(seen.payload.namespace, '.'), 'mcu.lifecycle.job_mcu_1.started')
	assert_eq(seen.payload.job_id, 'job/mcu.1')
	assert_eq(seen.payload.component, 'mcu')
	assert_eq(seen.payload.state, 'ready')
	assert_eq(seen.payload.source, 'device_component_fact')
end

function tests.test_emit_rejects_missing_component_or_phase()
	local ok_component, err_component = metrics.emit(nil, {}, {
		job_id = 'j1',
	}, 'started')
	assert_nil(ok_component)
	assert_eq(err_component, 'component_required')

	local ok_phase, err_phase = metrics.emit(nil, {}, {
		job_id = 'j1',
		component = 'mcu',
	}, '')
	assert_nil(ok_phase)
	assert_eq(err_phase, 'phase_required')
end

return tests
