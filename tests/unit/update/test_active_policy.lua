local policy = require 'services.update.active_policy'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end
local function assert_not_nil(v, msg)
	if v == nil then fail(msg or 'expected non-nil') end
end

function tests.test_artifact_missing_stage_resume_moves_mcu_job_to_reconcile()
	local job = {
		job_id = 'j1',
		component = 'mcu',
		state = 'staging',
		expected_image_id = 'img-1',
		adoption = { action = 'resume_active_intent' },
		active_intent = { phase = 'stage' },
		created_seq = 1,
		updated_seq = 1,
	}

	policy.apply_completion(job, {
		status = 'failed',
		phase = 'stage',
		primary = 'not_found',
	}, 2)

	assert_eq(job.state, 'awaiting_return')
	assert_eq(job.next_step, 'reconcile')
	assert_not_nil(job.commit_result)
	assert_eq(job.commit_result.tag, 'artifact_missing_reconcile')
	assert_eq(job.commit_result.expected_image_id, 'img-1')
	assert_eq(job.error, nil)
end

function tests.test_artifact_missing_stage_resume_without_identity_still_fails()
	local job = {
		job_id = 'j2',
		component = 'mcu',
		state = 'staging',
		adoption = { action = 'resume_active_intent' },
		active_intent = { phase = 'stage' },
		created_seq = 1,
		updated_seq = 1,
	}

	policy.apply_completion(job, {
		status = 'failed',
		phase = 'stage',
		primary = 'not_found',
	}, 2)

	assert_eq(job.state, 'failed')
	assert_eq(job.error, 'not_found')
end

return tests
