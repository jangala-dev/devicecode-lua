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

return T
