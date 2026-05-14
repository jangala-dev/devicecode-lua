local fibers = require 'fibers'
local runtime = require 'fibers.runtime'
local bus    = require 'bus'

local http_service = require 'services.http.service'
local sdk_mod      = require 'services.http.sdk'
local blob         = require 'devicecode.blob_source'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

local function yield_many(n)
	for _ = 1, n do runtime.yield() end
end

local function fake_driver()
	return {
		started = false,
		terminated = nil,
		start = function (self) self.started = true; return true end,
		terminate = function (self, reason) self.terminated = reason or true; return true end,
		run_op = function (_, _, fn) return fibers.guard(function () return fibers.always(fn()) end) end,
	}
end

local function failing_run_driver()
	return {
		terminated = nil,
		run = function () return nil, 'backend_boom' end,
		terminate = function (self, reason) self.terminated = reason or true; return true end,
		run_op = function (_, _, fn) return fibers.guard(function () return fibers.always(fn()) end) end,
	}
end

local function fake_headers(status)
	return {
		get = function (_, name) if name == ':status' then return tostring(status or 200) end end,
		each = function ()
			local rows = { { ':status', tostring(status or 200) }, { 'content-type', 'text/plain' } }
			local i = 0
			return function ()
				i = i + 1
				local row = rows[i]
				if row then return row[1], row[2] end
			end
		end,
	}
end

local function request_module(body)
	return {
		new_from_uri = function (uri)
			return {
				uri = uri,
				headers = {
					set = {},
					upsert = function (self, k, v) self.set[k] = v end,
					append = function (self, k, v) self.set[k] = v end,
				},
				go = function ()
					local chunks = { body or 'ok' }
					local i = 0
					return fake_headers(200), {
						get_next_chunk = function () i = i + 1; return chunks[i] end,
						shutdown = function () return true end,
					}
				end,
			}
		end,
	}
end

function M.test_backend_run_is_named_component_with_identity_completion()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local drv = failing_run_driver()
		local svc = ok(http_service.open_handle(root, { driver = drv, id = 'main' }))
		yield_many(10)
		local done
		for _, ev in ipairs(svc:events()) do
			if ev.kind == 'backend_done' then done = ev end
		end
		ok(done, 'backend_done completion should exist')
		eq(done.component, 'backend')
		eq(done.component_id, 'http_backend')
		eq(done.status, 'failed')
		eq(done.primary, 'backend_boom')
		local snap = svc:stats()
		eq(snap.backend, 'failed')
		eq(snap.last_error, 'backend_boom')
		svc:terminate('done')
	end)
end

function M.test_exchange_is_named_scoped_work_with_identity_completion_and_event_driven_summary()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local sink = blob.to_memory()
		local svc = ok(http_service.open_handle(root, {
			driver = fake_driver(),
			id = 'main',
			request_module = request_module('hello'),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local ref = sdk_mod.new_ref(user, 'main')
		local rep = ok(fibers.perform(ref:exchange_op({ uri = 'http://example.test/', method = 'GET', response_sink = sink })))
		eq(rep.result.status, '200')
		eq(rep.result.body, nil)
		eq(rep.result.response_sink.bytes, 5)
		eq(sink:result(), 'hello')
		yield_many(8)
		local events = svc:events()
		local started, done
		for _, ev in ipairs(events) do
			if ev.kind == 'operation_started' and ev.operation == 'exchange' then started = ev end
			if ev.kind == 'http_operation_done' and ev.operation == 'exchange' then done = ev end
		end
		ok(started, 'operation_started event should exist')
		ok(done, 'identity-bearing completion should exist')
		eq(done.operation_id, started.operation_id)
		eq(done.status, 'ok')
		local status = ok(fibers.perform(ref:status_op()))
		eq(status.status.completed_exchanges, 1)
		svc:terminate('done')
	end)
end

return M
