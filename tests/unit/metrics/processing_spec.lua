-- tests/unit/metrics/processing_spec.lua
--
-- Pure unit tests for services.metrics.processing blocks.
-- No fibers needed; all tests are synchronous function calls.

local processing = require 'services.metrics.processing'

local T = {}

function T.diff_trigger_absolute()
	local trigger = processing.DiffTrigger.new({
		threshold   = 5,
		diff_method = 'absolute',
		initial_val = 10,
	})
	local state = trigger:new_state()

	local val, short, err = trigger:run(12, state)
	assert(err == nil, tostring(err))
	assert(short == true, 'diff=2 < threshold 5, expected short-circuit')

	val, short, err = trigger:run(16, state)
	assert(err == nil, tostring(err))
	assert(short == false, 'diff=6 >= threshold 5, expected pass')
	assert(val == 16, 'expected val=16, got ' .. tostring(val))
end

function T.diff_trigger_percent()
	local trigger = processing.DiffTrigger.new({
		threshold   = 10,
		diff_method = 'percent',
		initial_val = 100,
	})
	local state = trigger:new_state()

	local val, short, err = trigger:run(105, state)
	assert(err == nil, tostring(err))
	assert(short == true, '5% < 10% threshold, expected short-circuit')

	val, short, err = trigger:run(115, state)
	assert(err == nil, tostring(err))
	assert(short == false, '15% >= 10% threshold, expected pass')
	assert(val == 115, 'expected val=115, got ' .. tostring(val))
end

function T.diff_trigger_any_change()
	local trigger = processing.DiffTrigger.new({
		diff_method = 'any-change',
		initial_val = 10,
	})
	local state = trigger:new_state()

	local val, short, err = trigger:run(10, state)
	assert(err == nil, tostring(err))
	assert(short == true, 'same value, expected short-circuit')

	val, short, err = trigger:run(10.1, state)
	assert(err == nil, tostring(err))
	assert(short == false, 'value changed, expected pass')
	assert(val == 10.1, 'expected val=10.1, got ' .. tostring(val))
end

function T.delta_value()
	local block = processing.DeltaValue.new({ initial_val = 10 })
	local state = block:new_state()

	local val, short, err = block:run(15, state)
	assert(err == nil, tostring(err))
	assert(short == false, 'expected no short-circuit')
	assert(val == 5, 'expected delta=5 (15-10), got ' .. tostring(val))

	block:reset(state)  -- simulate publish: last_val = 15

	val, short, err = block:run(20, state)
	assert(err == nil, tostring(err))
	assert(val == 5, 'expected delta=5 (20-15), got ' .. tostring(val))
end

function T.delta_value_counter_reset_reports_new_value()
	local block = processing.DeltaValue.new({})
	local state = block:new_state()

	block:run(5000, state)
	block:reset(state)  -- published: last_val = 5000

	-- The counter restarted (wifi reload) and has counted 300 since.
	local val, _, err = block:run(300, state)
	assert(err == nil, tostring(err))
	assert(val == 300, 'expected the post-reset value 300, got ' .. tostring(val))
end

function T.pipeline_run_and_reset()
	local pipeline, err = processing.new_process_pipeline()
	assert(err == nil, tostring(err))
	pipeline:add(processing.DeltaValue.new({ initial_val = 10 }))

	local state = pipeline:new_state()

	local val, short
	val, short, err = pipeline:run(20, state)
	assert(err == nil, tostring(err))
	assert(short == false, 'expected no short-circuit')
	assert(val == 10, 'expected delta=10 (20-10), got ' .. tostring(val))

	pipeline:reset(state)  -- last_val = 20

	val, short, err = pipeline:run(25, state)
	assert(err == nil, tostring(err))
	assert(val == 5, 'expected delta=5 (25-20), got ' .. tostring(val))
end

function T.pipeline_short_circuit()
	local pipeline, err = processing.new_process_pipeline()
	assert(err == nil, tostring(err))
	pipeline:add(processing.DiffTrigger.new({
		diff_method = 'absolute', threshold = 5, initial_val = 10,
	}))
	pipeline:add(processing.DeltaValue.new({ initial_val = 10 }))

	local state = pipeline:new_state()

	local val, short
	val, short, err = pipeline:run(20, state)  -- diff=10, passes DiffTrigger
	assert(err == nil, tostring(err))
	assert(short == false, 'expected pass through pipeline')
	assert(val == 10, 'expected DeltaValue delta=10, got ' .. tostring(val))

	val, short, err = pipeline:run(22, state)  -- diff=2 from last(20), short-circuits
	assert(err == nil, tostring(err))
	assert(short == true, 'expected short-circuit (diff=2 < threshold 5)')
end

local function shipped_counter_pipeline()
	-- Same shape as the network_stat template in src/configs.
	local pipeline = assert(processing.new_process_pipeline())
	pipeline:add(processing.DiffTrigger.new({
		diff_method = 'percent', threshold = 5, initial_val = 0,
	}))
	pipeline:add(processing.DeltaValue.new({}))
	return pipeline
end

-- After a devicecode restart the kernel counter keeps its value, so the first
-- sample is taken as the baseline instead of being reported as new traffic.
function T.pipeline_baseline_swallows_first_sample_and_reports_only_growth()
	local pipeline = shipped_counter_pipeline()
	local state = pipeline:new_state({ baseline_first_sample = true })

	local kernel = 20000000000
	local val, short, err = pipeline:run(kernel, state)
	assert(err == nil, tostring(err))
	assert(short == true, 'baseline sample should not be published')
	assert(val == nil, 'baseline sample should carry no value')
	assert(state.full_run == false, 'a swallowed sample is not a full run')

	-- 4% growth: under the trigger from the baseline, so nothing is sent.
	val, short, err = pipeline:run(kernel + 800000000, state)
	assert(err == nil, tostring(err))
	assert(short == true, '4% should not pass the 5% trigger')

	-- 6% growth: reported as exactly what was added since the baseline.
	val, short, err = pipeline:run(kernel + 1200000000, state)
	assert(err == nil, tostring(err))
	assert(short == false, '6% should pass the 5% trigger')
	assert(val == 1200000000, 'expected only the growth, got ' .. tostring(val))

	pipeline:reset(state)
	val, short, err = pipeline:run(kernel + 2400000000, state)
	assert(err == nil, tostring(err))
	assert(short == false, 'next 5% step should pass')
	assert(val == 1200000000, 'expected delta from the published value, got ' .. tostring(val))
end

function T.pipeline_without_baseline_keeps_counting_from_zero()
	local pipeline = shipped_counter_pipeline()
	local state = pipeline:new_state()

	local val, short, err = pipeline:run(1000, state)
	assert(err == nil, tostring(err))
	assert(short == false, 'expected publish')
	assert(val == 1000, 'expected delta=1000, got ' .. tostring(val))
end

-- A counter at zero rejects the percent trigger (0/0). The baseline must still be
-- taken from it, or the first real count would be swallowed as the baseline.
function T.pipeline_baseline_of_zero_does_not_swallow_the_first_real_count()
	local pipeline = shipped_counter_pipeline()
	local state = pipeline:new_state({ baseline_first_sample = true })

	local val, short, err = pipeline:run(0, state)
	assert(err == nil, tostring(err))
	assert(short == true, 'baseline sample should not be published')

	val, short, err = pipeline:run(1, state)
	assert(err == nil, tostring(err))
	assert(short == false, 'the first real error must publish')
	assert(val == 1, 'expected delta=1, got ' .. tostring(val))
end

function T.pipeline_baseline_handles_a_counter_reset_afterwards()
	local pipeline = assert(processing.new_process_pipeline())
	pipeline:add(processing.DeltaValue.new({}))
	local state = pipeline:new_state({ baseline_first_sample = true })

	local _, short = pipeline:run(5000, state)
	assert(short == true, 'baseline sample should not be published')

	local val, err
	val, short, err = pipeline:run(6000, state)
	assert(err == nil, tostring(err))
	assert(val == 1000, 'expected delta from the baseline, got ' .. tostring(val))

	val, short, err = pipeline:run(300, state)
	assert(err == nil, tostring(err))
	assert(short == false, 'expected publish')
	assert(val == 300, 'a lower counter was reset, so the value is the change; got ' .. tostring(val))
end

function T.pipeline_baseline_is_ignored_without_a_delta_block()
	local pipeline = assert(processing.new_process_pipeline())
	pipeline:add(processing.DiffTrigger.new({ diff_method = 'any-change' }))
	local state = pipeline:new_state({ baseline_first_sample = true })

	local val, short, err = pipeline:run('bigbox-v1', state)
	assert(err == nil, tostring(err))
	assert(short == false, 'identity-style metrics must still publish')
	assert(val == 'bigbox-v1', 'expected the value through, got ' .. tostring(val))
end

function T.pipeline_baseline_still_reports_a_non_number()
	local pipeline = assert(processing.new_process_pipeline())
	pipeline:add(processing.DeltaValue.new({}))
	local state = pipeline:new_state({ baseline_first_sample = true })
	local _, _, err = pipeline:run('not-a-number', state)
	assert(err ~= nil, 'expected the existing error for a non-number')
end

-- A config change replaces pipeline state. A counter already being tracked carries
-- on from where it was, rather than reporting the whole counter or losing traffic.
function T.pipeline_resumes_a_counter_after_a_state_replacement()
	local pipeline = shipped_counter_pipeline()
	local old = pipeline:new_state()
	pipeline:run(100000, old)
	pipeline:reset(old)
	pipeline:run(110000, old)
	assert(pipeline:counter_value(old) == 110000, 'expected the counter last taken up')

	local state = pipeline:new_state({ resume_counter = pipeline:counter_value(old) })
	local val, short, err = pipeline:run(120000, state)
	assert(err == nil, tostring(err))
	assert(short == false, '9% should pass the 5% trigger')
	assert(val == 10000, 'expected only the growth, got ' .. tostring(val))
end

function T.pipeline_without_a_delta_block_has_no_counter_to_resume()
	local pipeline = assert(processing.new_process_pipeline())
	pipeline:add(processing.DiffTrigger.new({ diff_method = 'any-change' }))
	local state = pipeline:new_state()
	pipeline:run('x', state)
	assert(pipeline:counter_value(state) == nil, 'expected no counter')
end

return T
