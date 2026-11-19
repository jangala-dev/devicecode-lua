local T = {}

function T.tracker_returns_new_states_and_exhausts_after_three_retries()
	local retry = require 'services.metrics.http_retry'
	local state = retry.next(nil, 'bad_request')
	assert(state.outcome == 'bad_request' and state.success == false)
	assert(state.retry == 0 and state.max_retries == 3)
	for count = 1, 3 do
		assert(not retry.is_exhausted(state))
		local previous = state
		state = retry.next(state, 'bad_request')
		assert(state ~= previous and previous.retry == count - 1)
		assert(state.retry == count)
	end
	assert(retry.is_exhausted(state))
	state = retry.next(state, 'server_failure')
	assert(state.retry == 0 and state.max_retries == math.huge)
	assert(not retry.is_exhausted(state))
	state = retry.next(state, 'bad_request')
	assert(state.retry == 0 and not retry.is_exhausted(state))
end

function T.unlimited_outcomes_never_exhaust_and_backoff_is_capped()
	local retry = require 'services.metrics.http_retry'
	for _, outcome in ipairs({ 'timeout', 'network_failure', 'request_timeout', 'rate_limited', 'server_failure' }) do
		local state
		for count = 0, 100 do
			state = retry.next(state, outcome)
			assert(state.retry == count and state.max_retries == math.huge)
			assert(not retry.is_exhausted(state))
			assert(retry.delay(state, {}, 0) == math.min(2 ^ math.min(count, 6), 60))
		end
	end
end

function T.success_and_one_shot_override_retry_limits()
	local retry = require 'services.metrics.http_retry'
	assert(retry.next(nil, 'success', true).success == true)
	assert(not retry.is_exhausted(retry.next(nil, 'success')))
	assert(retry.is_exhausted(retry.next(nil, 'server_failure', true)))
	assert(retry.is_exhausted(retry.next(nil, 'permanent_failure')))
end

function T.retry_after_supports_seconds_dates_and_case_insensitive_headers()
	local retry = require 'services.metrics.http_retry'
	local state = retry.next(nil, 'server_failure')
	for _, value in ipairs({ '120', ' 120\t', 'Tue, 14 Nov 2023 22:15:20 GMT',
		'Tuesday, 14-Nov-23 22:15:20 GMT', 'Tue Nov 14 22:15:20 2023' }) do
		assert(retry.delay(state, { ['Retry-After'] = value }, 1700000000) == 120, value)
	end
	for _, value in ipairs({ '0', '-1', '1.5', 'garbage', '120garbage', '1e309',
		string.rep('9', 400), 'Tue, 14 Nov 2023 22:00:00 GMT',
		'Tue, 31 Feb 2023 22:15:20 GMT', 'Tue, 14 Nov 2023 99:15:20 GMT', false, {} }) do
		assert(retry.delay(state, { ['retry-after'] = value }, 1700000000) == 1, tostring(value))
	end
	state = retry.next(state, 'server_failure')
	assert(retry.delay(state, { ['retry-after'] = '1' }, 1700000000) == 2)
end

return T
