local fibers = require 'fibers'
local runtime = require 'fibers.runtime'
local driver_mod = require 'services.http.transport.cqueues_driver'
local client = require 'services.http.client'
local blob = require 'devicecode.blob_source'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

local function yield_once()
	runtime.yield()
end

local function yield_until(pred, msg)
	for _ = 1, 50 do
		if pred() then return true end
		yield_once()
	end
	error(msg or 'condition was not reached', 2)
end

local function fake_controller()
	local q = {}
	return {
		wrap = function (self, fn) q[#q + 1] = fn; return self end,
		step = function () local fn = table.remove(q, 1); if fn then fn() end; return true end,
		pollfd = function () return nil end,
		events = function () return '' end,
		timeout = function () return nil end,
	}
end

local function fake_driver()
	return {
		run_op = function (_, _, fn)
			return fibers.guard(function () return fibers.always(fn()) end)
		end,
	}
end

local function fake_condition_factory()
	local c = require 'fibers.cond'
	local wake = c.new()
	return {
		wait = function () return fibers.perform(wake:wait_op()) end,
		signal = function () wake:signal(); wake = c.new(); return true end,
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

local function request_module(body_text)
	return {
		new_from_uri = function (uri)
			return {
				uri = uri,
				headers = {
					set = {},
					upsert = function (self, k, v) self.set[k] = v end,
					append = function (self, k, v) self.set[k] = v end,
				},
				set_body = function (self, body_iter) self.body_iter = body_iter end,
				go = function (self)
					local chunks = { body_text or ('body for ' .. self.uri) }
					local i = 0
					return fake_headers(202), {
						get_next_chunk = function () i = i + 1; return chunks[i] end,
						shutdown = function () self.shutdown = true; return true end,
					}
				end,
			}
		end,
	}
end

function M.test_exchange_op_streams_response_to_sink_without_returning_body()
	fibers.run(function ()
		local sink = blob.to_memory()
		local result = ok(fibers.perform(client.exchange_op(fake_driver(), {
			uri = 'http://example.test/path',
			method = 'GET',
			headers = { ['x-test'] = 'yes' },
			response_sink = sink,
		}, { request_module = request_module('hello') })))
		eq(result.status, '202')
		eq(result.body, nil)
		eq(result.response_sink.bytes, 5)
		eq(sink:result(), 'hello')
		eq(result.headers['content-type'], 'text/plain')
	end)
end

function M.test_open_exchange_rejects_raw_body_before_backend_job()
	fibers.run(function ()
		local called = false
		local drv = { run_op = function () called = true; return fibers.always('bad') end }
		local ex, err = fibers.perform(client.open_exchange_op(drv, {
			uri = 'http://example.test/',
			method = 'POST',
			body = 'raw bytes',
		}, { request_module = request_module() }))
		eq(ex, nil)
		eq(err, 'invalid_args')
		eq(called, false)
	end)
end

function M.test_request_source_streams_through_fibers_native_body_pipe()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local sent_body = {}
	local request_mod = {
		new_from_uri = function (uri)
			return {
				uri = uri,
				headers = {
					set = {},
					upsert = function (self, k, v) self.set[k] = v end,
					append = function (self, k, v) self.set[k] = v end,
				},
				set_body = function (self, iter) self.body_iter = iter end,
				go = function (self)
					while true do
						local chunk = self.body_iter and self.body_iter() or nil
						if chunk == nil then break end
						sent_body[#sent_body + 1] = chunk
					end
					local chunks = { 'ok' }
					local i = 0
					return fake_headers(201), {
						get_next_chunk = function () i = i + 1; return chunks[i] end,
						shutdown = function () return true end,
					}
				end,
			}
		end,
	}

	fibers.run(function (scope)
		assert(drv:start(scope))
		local result = ok(fibers.perform(client.exchange_op(drv, {
			uri = 'http://example.test/', method = 'POST', body_source = blob.from_string('abcd'),
		}, {
			request_module = request_mod,
			request_body_condition_factory = fake_condition_factory,
		})))
		eq(result.status, '201')
		eq(table.concat(sent_body), 'abcd')
		drv:terminate('done')
	end)
end


function M.test_exchange_op_does_not_terminate_committed_response_sink_after_success()
	fibers.run(function ()
		local committed = false
		local terminated = nil
		local sink = {
			write_chunk_op = function () return fibers.always(true) end,
			commit_op = function () committed = true; return fibers.always(true) end,
			terminate = function (_, reason) terminated = reason or true; return true end,
		}

		local result = ok(fibers.perform(client.exchange_op(fake_driver(), {
			uri = 'http://example.test/path',
			method = 'GET',
			response_sink = sink,
		}, { request_module = request_module('hello') })))
		eq(result.response_sink.bytes, 5)
		eq(committed, true, 'sink commit must run')
		eq(terminated, nil, 'committed sink ownership must not be reclaimed by the exchange finaliser')
	end)
end

function M.test_exchange_op_terminates_uncommitted_response_sink_on_copy_failure()
	fibers.run(function ()
		local terminated = nil
		local sink = {
			write_chunk_op = function () return fibers.always(nil, 'sink_failed') end,
			commit_op = function () error('commit must not run after write failure', 0) end,
			terminate = function (_, reason) terminated = reason or true; return true end,
		}

		local result, err = fibers.perform(client.exchange_op(fake_driver(), {
			uri = 'http://example.test/path',
			method = 'GET',
			response_sink = sink,
		}, { request_module = request_module('hello') }))
		eq(result, nil)
		eq(err, 'sink_failed')
		eq(terminated, 'failed', 'uncommitted sink must be terminated by the operation scope')
	end)
end


function M.test_request_body_source_without_read_op_rejects_before_request_construction()
	fibers.run(function ()
		local constructed = 0
		local request_mod = {
			new_from_uri = function () constructed = constructed + 1; return request_module().new_from_uri('http://example.test/') end,
		}
		local result, err = fibers.perform(client.exchange_op(fake_driver(), {
			uri = 'http://example.test/', method = 'POST', body_source = { terminate = function () return true end },
		}, { request_module = request_mod }))
		eq(result, nil)
		eq(err, 'invalid_args')
		eq(constructed, 0, 'invalid request source must reject before lua-http request construction')
	end)
end

function M.test_open_exchange_active_abort_terminates_active_request_not_driver()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local go_active = false
	local req_closed = false
	local request_mod = {
		new_from_uri = function (uri)
			return {
				uri = uri,
				headers = {
					upsert = function () end,
					append = function () end,
				},
				go = function (self)
					go_active = true
					while not req_closed do runtime.yield() end
					return nil, 'cancelled'
				end,
				cancel = function (_, reason) req_closed = reason or true; return true end,
				shutdown = function () error('active open_exchange abort must not use graceful request shutdown', 0) end,
			}
		end,
	}

	fibers.run(function (scope)
		assert(drv:start(scope))
		local waiter = assert(scope:child())
		assert(waiter:spawn(function ()
			fibers.perform(client.open_exchange_op(drv, {
				uri = 'http://example.test/',
				method = 'GET',
			}, { request_module = request_mod }))
		end))

		yield_until(function () return go_active end, 'request go should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		ok(req_closed, 'active open_exchange abort should terminate the request')
		ok(not drv:is_closed(), 'request termination is the narrow owner; driver should survive')
		drv:terminate('done')
	end)
end

function M.test_exchange_read_active_abort_terminates_exchange_not_driver()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local read_active = false
	local stream
	stream = {
		terminated = false,
		connection = {
			take_socket = function (conn)
				return {
					close = function ()
						stream.terminated = true
						conn.taken = true
						return true
					end,
				}
			end,
		},
		get_next_chunk = function (self)
			read_active = true
			while not self.terminated do runtime.yield() end
			return nil
		end,
		shutdown = function ()
			error('active exchange abort must not use graceful stream shutdown', 0)
		end,
	}
	local ex = client.HttpExchange and client.HttpExchange.make
	-- The public client module exposes the class for type checks; construct via
	-- the ordinary open path shape by requiring the handle module directly here.
	ex = require('services.http.exchange').make(drv, fake_headers(200), stream, {})

	fibers.run(function (scope)
		assert(drv:start(scope))
		local waiter = assert(scope:child())
		assert(waiter:spawn(function () fibers.perform(ex:read_chunk_op()) end))
		yield_until(function () return read_active end, 'exchange read should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		ok(stream.terminated, 'active exchange read abort should terminate stream')
		ok(ex:is_closed(), 'exchange handle should be marked closed')
		ok(not drv:is_closed(), 'exchange is the narrow owner; driver should survive')
		drv:terminate('done')
	end)
end

return M
