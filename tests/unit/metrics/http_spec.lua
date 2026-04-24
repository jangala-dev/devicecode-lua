-- tests/unit/metrics/http_spec.lua
--
-- Unit test for the HTTP publisher module.
-- Stubs http.request before loading services.metrics.http so no real network
-- traffic is made.  Uses runfibers + virtual_time for deterministic timing.

local fibers       = require 'fibers'
local perform      = fibers.perform
local time_harness = require 'tests.support.time_harness'
local virtual_time = require 'tests.support.virtual_time'
local runfibers    = require 'tests.support.run_fibers'

local T = {}

function T.start_http_publisher_builds_expected_request()
	-- Save originals so we can restore after the test.
	local original_http_request = package.loaded['http.request']
	local original_http_module  = package.loaded['services.metrics.http']

	local captured = {
		uri           = nil,
		method        = nil,
		auth          = nil,
		content_type  = nil,
		expect_header = 'present',  -- sentinel; nil means the header was deleted
		body          = nil,
		timeout       = nil,
	}

	-- Stub http.request with a mock that captures what the publisher sends.
	package.loaded['http.request'] = {
		new_from_uri = function(uri)
			captured.uri = uri

			local hdr = {}
			local req = {
				headers = {
					upsert = function(_, k, v) hdr[k] = v end,
					delete = function(_, k)    hdr[k] = nil end,
				},
				set_body = function(_, body)
					captured.body = body
				end,
				go = function(_, timeout)
					captured.timeout      = timeout
					captured.method       = hdr[':method']
					captured.auth         = hdr['authorization']
					captured.content_type = hdr['content-type']
					captured.expect_header = hdr['expect']
					return {
						get = function(_, key)
							if key == ':status' then return '202' end
							return nil
						end,
						each = function()
							return function() return nil end
						end,
					}
				end,
			}
			return req
		end,
	}

	-- Force a fresh load so it picks up the stub above.
	package.loaded['services.metrics.http'] = nil

	local ok_run, run_err = pcall(function()
		runfibers.run(function(scope)
			local clock = virtual_time.install({ monotonic = 0, realtime = 1700000000 })

			local http_mod = require 'services.metrics.http'

			local worker_scope = scope:child()

			local spawn_ok, spawn_err = worker_scope:spawn(function()
				local ch = http_mod.start_http_publisher()

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
			assert(captured.expect_header == nil,
				'expected Expect header to be deleted, got ' .. tostring(captured.expect_header))
			assert(captured.body == '[{"n":"sim","vs":"present"}]',
				'unexpected body: ' .. tostring(captured.body))
			assert(captured.timeout == 10,
				'expected timeout=10, got ' .. tostring(captured.timeout))

			worker_scope:cancel('test done')
			perform(worker_scope:join_op())

			clock:restore()
		end, { timeout = 2.0 })
	end)

	-- Restore stubs regardless of test outcome.
	package.loaded['http.request']          = original_http_request
	package.loaded['services.metrics.http'] = original_http_module

	assert(ok_run, tostring(run_err))
end

return T
