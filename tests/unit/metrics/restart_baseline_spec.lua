-- tests/unit/metrics/restart_baseline_spec.lua
--
-- A devicecode restart leaves the kernel counters running, so endpoints already
-- counting before it must not report their whole counter as new traffic.

local cjson = require 'cjson.safe'
local runtime = require 'fibers.runtime'
local metrics = require 'services.metrics'
local conf = require 'services.metrics.config'
local processing = require 'services.metrics.processing'

local T = {}

local function delta_pipeline()
	local pipeline = assert(processing.new_process_pipeline())
	pipeline:add(processing.DeltaValue.new({}))
	return pipeline
end

local function reset_state(pipeline, baseline_until)
	local State = metrics._test.State
	State.pipelines_map = { rx_bytes = { pipeline = pipeline, protocol = 'http' } }
	State.metric_states, State.endpoint_to_pipe, State.endpoint_seen, State.metric_values = {}, {}, {}, {}
	State.svc = { obs_log = function () end }
	State.baseline_until = baseline_until
	return State
end

local function counter_msg(value)
	return {
		topic = { 'obs', 'v1', 'net', 'metric', 'rx_bytes' },
		payload = { value = value, namespace = { 'net', 'wan', 'rx_bytes' } },
	}
end

local function queued_value(State)
	local http = State.metric_values.http
	local sample = http and http['net.wan.rx_bytes']
	return sample and sample.value
end

function T.first_sample_inside_the_window_is_a_baseline()
	local State = reset_state(delta_pipeline(), runtime.now() + 10)
	metrics._test.handle_metric(counter_msg(20000000000))
	assert(queued_value(State) == nil, 'expected nothing queued for the baseline sample')

	metrics._test.handle_metric(counter_msg(20000000500))
	assert(queued_value(State) == 500, 'expected only the growth, got ' .. tostring(queued_value(State)))
end

function T.first_sample_after_the_window_is_real_traffic()
	local State = reset_state(delta_pipeline(), runtime.now() - 1)
	metrics._test.handle_metric(counter_msg(1000))
	assert(queued_value(State) == 1000, 'expected the first sample to count, got ' .. tostring(queued_value(State)))
end

function T.first_sample_on_a_fresh_boot_is_real_traffic()
	local State = reset_state(delta_pipeline(), nil)
	metrics._test.handle_metric(counter_msg(1000))
	assert(queued_value(State) == 1000, 'expected the first sample to count, got ' .. tostring(queued_value(State)))
end

-- The failure seen in the field, through the rx_bytes pipeline each target ships.
function T.shipped_pipelines_report_only_real_traffic_across_restarts()
	for _, target in ipairs({ 'bigbox-ss', 'bigbox-v1-cm', 'bigbox-v1-cm-2' }) do
		local f = assert(io.open('../src/configs/' .. target .. '.json'))
		local cfg = assert(cjson.decode(f:read('*a')))
		f:close()
		local pipeline = assert(conf.apply_config(cfg.metrics).rx_bytes, target .. ': no rx_bytes pipeline').pipeline

		local reported = 0
		local function sample(state, value)
			local delta, short = pipeline:run(value, state)
			if not short then
				reported = reported + delta
				pipeline:reset(state)
			end
		end

		local kernel = 20000000000
		sample(pipeline:new_state(), kernel) -- fresh boot: all of this is real traffic

		for _ = 1, 3 do
			local state = pipeline:new_state({ baseline_first_sample = true })
			kernel = kernel + 100000000 -- traffic during the restart goes uncounted
			sample(state, kernel)
			kernel = kernel + 2000000000 -- 10%: past the 5% trigger
			sample(state, kernel)
		end

		local expected = 20000000000 + 3 * 2000000000
		assert(reported == expected,
			target .. ': expected ' .. expected .. ' bytes, reported ' .. reported)
	end
end

return T
