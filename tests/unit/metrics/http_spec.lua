-- tests/unit/metrics/http_spec.lua
--
-- Unit test for the HTTP publisher module.
-- Supplies a stub http_ref whose exchange_op records what it receives so no
-- real network traffic is made.  Uses runfibers + virtual_time for
-- deterministic timing.

local fibers       = require 'fibers'
local op           = require 'fibers.op'
local perform      = fibers.perform
local time_harness = require 'tests.support.time_harness'
local virtual_time = require 'tests.support.virtual_time'
local runfibers    = require 'tests.support.run_fibers'

local T = {}

-- Build a stub http_ref whose exchange_op immediately resolves with the given
-- HTTP status, and records what it was called with.
local function make_fake_ref(captured, reply_status)
	local ref = {}
	function ref:exchange_op(args)
		captured.method       = args.method
		captured.uri          = args.uri
		captured.auth         = args.headers and args.headers.authorization
		captured.content_type = args.headers and args.headers['content-type']
		captured.body_source  = args.body_source
		return op.always({ result = { status = reply_status or '202', headers = {} } })
	end
	return ref
end

function T.start_http_publisher_sends_expected_request()
	local original_http_module = package.loaded['services.metrics.http']

	local captured = {}

	-- Force a fresh load.
	package.loaded['services.metrics.http'] = nil

	local ok_run, run_err = pcall(function()
		runfibers.run(function(scope)
			local clock = virtual_time.install({ monotonic = 0, realtime = 1700000000 })
			scope:finally(function() clock:restore() end)

			local http_mod     = require 'services.metrics.http'
			local fake_ref     = make_fake_ref(captured, '202')
			local worker_scope = scope:child()

			local spawn_ok, spawn_err = worker_scope:spawn(function()
				local ch = http_mod.start_http_publisher(fake_ref)

				perform(ch:put_op({
					uri  = 'http://localhost:18080/http/channels/ch-data/messages',
					auth = 'Thing test-thing-key',
					body = '[{"n":"sim","vs":"present"}]',
				}))
			end)
			assert(spawn_ok, tostring(spawn_err))

			time_harness.flush_ticks(20)

			assert(captured.uri == 'http://localhost:18080/http/channels/ch-data/messages',
				'unexpected uri: ' .. tostring(captured.uri))
			assert(captured.method == 'POST',
				'expected method=POST, got ' .. tostring(captured.method))
			assert(captured.auth == 'Thing test-thing-key',
				'unexpected auth: ' .. tostring(captured.auth))
			assert(captured.content_type == 'application/senml+json',
				'unexpected content-type: ' .. tostring(captured.content_type))
			assert(captured.body_source ~= nil,
				'expected body_source to be set')

			worker_scope:cancel('test done')
			perform(worker_scope:join_op())
		end, { timeout = 2.0 })
	end)

	package.loaded['services.metrics.http'] = original_http_module

	assert(ok_run, tostring(run_err))
end

-- The cloud's answer reaches the sender, so a crash record stays on file if refused.
local function on_result_for_status(status)
	local original_http_module = package.loaded['services.metrics.http']
	package.loaded['services.metrics.http'] = nil
	local answer = nil

	local ok_run, run_err = pcall(function()
		runfibers.run(function(scope)
			local clock = virtual_time.install({ monotonic = 0, realtime = 1700000000 })
			scope:finally(function() clock:restore() end)

			local http_mod     = require 'services.metrics.http'
			local worker_scope = scope:child()
			local spawn_ok, spawn_err = worker_scope:spawn(function()
				local ch = http_mod.start_http_publisher(make_fake_ref({}, status))
				perform(ch:put_op({
					uri = 'http://x/', auth = 'Thing k', body = '[]', one_shot = true,
					on_result = function(accepted) answer = accepted end,
				}))
			end)
			assert(spawn_ok, tostring(spawn_err))

			time_harness.flush_ticks(20)
			worker_scope:cancel('test done')
			perform(worker_scope:join_op())
		end, { timeout = 2.0 })
	end)

	package.loaded['services.metrics.http'] = original_http_module
	if not ok_run then error(run_err, 0) end
	return answer
end

function T.on_result_reports_an_accepted_send()
	assert(on_result_for_status('202') == true, 'expected accepted')
end

function T.on_result_reports_a_refused_send()
	assert(on_result_for_status('503') == false, 'expected refused')
end

-- A one-shot send doesn't retry: the sender paces its own retries, and metered
-- SIMs shouldn't pay for a crash record again every few seconds during an outage.
function T.one_shot_send_reports_a_network_failure_without_retrying()
	local original_http_module = package.loaded['services.metrics.http']
	package.loaded['services.metrics.http'] = nil
	local answer, attempts = nil, 0

	local ok_run, run_err = pcall(function()
		runfibers.run(function(scope)
			local clock = virtual_time.install({ monotonic = 0, realtime = 1700000000 })
			scope:finally(function() clock:restore() end)

			local ref = {}
			function ref:exchange_op()
				attempts = attempts + 1
				return op.always(nil, 'network unreachable')
			end

			local http_mod     = require 'services.metrics.http'
			local worker_scope = scope:child()
			assert(worker_scope:spawn(function()
				local ch = http_mod.start_http_publisher(ref)
				perform(ch:put_op({
					uri = 'http://x/', auth = 'Thing k', body = '[]', one_shot = true,
					on_result = function(accepted) answer = accepted end,
				}))
			end))

			-- A retry would come after 1 s, and again 2 s after that.
			for _ = 1, 8 do
				clock:advance(0.5)
				time_harness.flush_ticks(20)
			end
			worker_scope:cancel('test done')
			perform(worker_scope:join_op())
		end, { timeout = 10.0 }) -- on the virtual clock, which this spec advances
	end)

	package.loaded['services.metrics.http'] = original_http_module
	if not ok_run then error(run_err, 0) end
	assert(attempts == 1, 'expected one attempt, got ' .. attempts)
	assert(answer == false, 'expected the failure to be reported, got ' .. tostring(answer))
end

-- Script outcomes through the public publisher using deterministic time.
local function with_publisher(replies, check, opts)
	opts = opts or {}
	runfibers.run(function(scope)
		local clock = virtual_time.install({ monotonic = 0, realtime = 1700000000 })
		scope:finally(function() clock:restore() end)
		local s = { attempts = {}, answers = {}, logs = {} }
		local ref = {}
		function ref:exchange_op(args)
			s.attempts[#s.attempts + 1] = { args = args, time = clock:monotonic() }
			local reply = replies[#s.attempts] or '202'
			if reply == 'timeout' then return op.never() end
			if reply == 'network' then return op.always(nil, 'network unreachable') end
			if type(reply) ~= 'table' then reply = { status = reply, headers = {} } end
			return op.always({ result = reply })
		end
		local worker = scope:child()
		local ch
		assert(worker:spawn(function()
			ch = require('services.metrics.http').start_http_publisher(ref, function(_, entry)
				assert(require('cjson.safe').encode(entry), 'publisher logs must be JSON encodable')
				s.logs[#s.logs + 1] = entry
			end)
		end))
		local function settle() time_harness.flush_ticks(100) end
		settle()
		assert(ch, 'publisher did not become ready')
		function s:enqueue(body)
			perform(ch:put_op({ uri = 'http://x/', auth = 'Thing k', body = body or '[]',
				one_shot = opts.one_shot,
				on_result = function(answer) self.answers[#self.answers + 1] = answer end,
			}))
			settle()
		end
		function s:advance(dt) clock:advance(dt); settle() end
		function s:cancel()
			worker:cancel('test done')
			perform(worker:join_op())
		end
		s:enqueue()
		check(s)
		s:cancel()
	end, { timeout = 10000 })
end

function T.all_success_statuses_complete_without_retry()
	for _, status in ipairs({ '200', '201', '202', '204', '299', 202 }) do
		with_publisher({ status }, function(s)
			assert(#s.answers == 1 and s.answers[1] == true, tostring(status))
			s:advance(60)
			assert(#s.attempts == 1)
		end)
	end
end

function T.transient_http_failures_retry_then_report_success_once()
	for _, status in ipairs({ '408', '429', '500', '502', '503', '504', '599' }) do
		with_publisher({ status, '202' }, function(s)
			assert(#s.answers == 0, 'intermediate failure must not finish the payload')
			s:advance(0.5)
			assert(#s.attempts == 1, 'retried too early')
			s:advance(0.5)
			assert(#s.attempts == 2, 'expected retry for ' .. status)
			assert(#s.answers == 1 and s.answers[1] == true)
		end)
	end
end

function T.permanent_or_invalid_replies_drop_and_advance_the_queue()
	for _, status in ipairs({ '401', '403', '404', '413', '422', '302', 'invalid', false }) do
		with_publisher({ { status = status } }, function(s)
			assert(#s.answers == 1 and s.answers[1] == false, tostring(status))
			s:enqueue('next payload')
			assert(#s.attempts == 2 and s.answers[2] == true)
		end)
	end
end

function T.bad_request_allows_three_retries_before_dropping()
	with_publisher({ '400', '400', '400', '400' }, function(s)
		for i, delay in ipairs({ 1, 2, 4 }) do
			assert(#s.answers == 0)
			s:advance(delay)
			assert(#s.attempts == i + 1)
		end
		assert(#s.answers == 1 and s.answers[1] == false)
		local entry = s.logs[#s.logs]
		assert(entry.what == 'http_publish_failed' and entry.outcome == 'bad_request')
		assert(entry.retry == 3 and entry.max_retries == 3)
		s:enqueue()
		assert(#s.attempts == 5 and s.answers[2] == true)
	end)
end

function T.outcome_changes_reset_the_retry_count_and_backoff()
	with_publisher({ '400', '400', '503', '400', '400', '400', '202' }, function(s)
		for _, delay in ipairs({ 1, 2, 1, 1, 2, 4 }) do s:advance(delay) end
		assert(#s.attempts == 7 and #s.answers == 1 and s.answers[1] == true)
	end)
end

function T.server_failures_share_backoff_capped_at_sixty_seconds()
	with_publisher({ '502', '503', '504', '502', '503', '504', '502', '503', '202' }, function(s)
		for i, delay in ipairs({ 1, 2, 4, 8, 16, 32, 60, 60 }) do
			s:advance(delay - 0.5)
			assert(#s.attempts == i, 'retried before backoff elapsed')
			s:advance(0.5)
			assert(#s.attempts == i + 1)
		end
		assert(s.answers[1] == true)
	end)
end

function T.network_failure_and_request_timeout_retry()
	for _, outcome in ipairs({ 'network', 'timeout' }) do
		with_publisher({ outcome, '202' }, function(s)
			if outcome == 'timeout' then
				s:advance(59)
				assert(#s.attempts == 1 and #s.answers == 0)
				s:advance(1)
			end
			s:advance(1)
			assert(#s.attempts == 2 and s.answers[1] == true)
		end)
	end
end

function T.every_retry_sends_the_complete_body_from_a_fresh_source()
	with_publisher({ '503', '202' }, function(s)
		local first = s.attempts[1].args.body_source
		assert(perform(first:read_chunk_op()) == '[]')
		assert(perform(first:read_chunk_op()) == nil)
		s:advance(1)
		local second = s.attempts[2].args.body_source
		assert(first ~= second and perform(second:read_chunk_op()) == '[]')
		assert(s.attempts[2].args.headers.authorization == 'Thing k')
	end)
end

function T.new_payload_starts_with_fresh_retry_state()
	with_publisher({ '503', '503', '202', '503', '202' }, function(s)
		s:advance(1)
		s:advance(2)
		assert(s.answers[1] == true)
		s:enqueue()
		assert(#s.attempts == 4 and #s.answers == 1)
		s:advance(1)
		assert(#s.attempts == 5 and s.answers[2] == true)
	end)
end

function T.retry_after_delays_the_retry_and_remains_cancellable()
	for _, header in ipairs({ '120', 'Tue, 14 Nov 2023 22:15:20 GMT' }) do
		with_publisher({ { status = '503', headers = { ['retry-after'] = header } }, '202' }, function(s)
			s:advance(119)
			assert(#s.attempts == 1 and #s.answers == 0)
			s:advance(1)
			assert(#s.attempts == 2 and s.answers[1] == true)
		end)
	end
	with_publisher({ { status = '503', headers = { ['retry-after'] = '3600' } } }, function(s)
		s:cancel()
		s:advance(3601)
		assert(#s.attempts == 1 and #s.answers == 0)
	end)
end

function T.cancelling_an_inflight_request_stops_the_publisher()
	with_publisher({ 'timeout' }, function(s)
		s:cancel()
		s:advance(61)
		assert(#s.attempts == 1 and #s.answers == 0)
	end)
end

function T.one_shot_never_retries_any_failure()
	for _, outcome in ipairs({ 'network', 'timeout', '400', '408', '429', '503' }) do
		with_publisher({ outcome }, function(s)
			if outcome == 'timeout' then s:advance(60) end
			assert(#s.answers == 1 and s.answers[1] == false)
			s:advance(120)
			assert(#s.attempts == 1 and #s.answers == 1)
		end, { one_shot = true })
	end
end

return T
