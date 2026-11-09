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
					uri = 'http://x/', auth = 'Thing k', body = '[]',
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

return T
