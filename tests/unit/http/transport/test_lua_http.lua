local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local driver_mod = require 'services.http.transport.cqueues_driver'
local lua_http = require 'services.http.transport.lua_http'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
end

local function yield_once()
	runtime.yield()
end

local function yield_many(n)
	for _ = 1, n do yield_once() end
end

local function yield_until(pred, msg)
	for _ = 1, 50 do
		if pred() then return true end
		yield_once()
	end
	error(msg or 'condition was not reached', 2)
end

local function fake_condition()
	return {
		signals = 0,
		waits = 0,
		signal = function (self) self.signals = self.signals + 1; return true end,
		wait = function (self) self.waits = self.waits + 1; return true end,
	}
end

local function fake_server()
	return {
		steps = 0,
		closed = false,
		listened = false,
		pollfd = function () return nil end,
		events = function () return '' end,
		timeout = function () return nil end,
		step = function (self, timeout)
			eq(timeout, 0)
			self.steps = self.steps + 1
			return true
		end,
		listen = function (self, timeout)
			self.listened = timeout or true
			return true
		end,
		close = function (self)
			self.closed = true
			return true
		end,
		pause = function (self) self.paused = true; return true end,
		resume = function (self) self.resumed = true; return true end,
	}
end

local function fake_stream()
	return {
		terminated = false,
		calls = {},
		shutdown = function (self) self.terminated = true; return true end,
		get_headers = function (self, timeout) self.calls[#self.calls+1] = {'headers', timeout}; return { ':method', 'GET' } end,
		get_next_chunk = function (self, timeout) self.calls[#self.calls+1] = {'chunk', timeout}; return 'chunk', false end,
		get_body_chars = function (self, n, timeout) self.calls[#self.calls+1] = {'chars', n, timeout}; return string.rep('x', n) end,
		get_body_as_string = function (self, timeout) self.calls[#self.calls+1] = {'body', timeout}; return 'body' end,
		write_headers = function (self, headers, end_stream, timeout) self.calls[#self.calls+1] = {'write_headers', headers, end_stream, timeout}; return true end,
		write_chunk = function (self, chunk, end_stream, timeout) self.calls[#self.calls+1] = {'write_chunk', chunk, end_stream, timeout}; return true end,
		write_body_from_string = function (self, body, timeout) self.calls[#self.calls+1] = {'write_body', body, timeout}; return true end,
	}
end

local function listener_with(opts)
	opts = opts or {}
	local drv = opts.driver or assert(driver_mod.new { create_controller = false })
	return assert(lua_http.listen {
		server = opts.server or fake_server(),
		driver = drv,
		max_accept_queue = opts.max_accept_queue,
		condition_factory = function () return fake_condition() end,
		context_terminator = opts.context_terminator,
		intra_stream_timeout = opts.intra_stream_timeout,
		on_context = opts.on_context,
	})
end

function M.test_listener_admits_context_and_accept_op_returns_it()
	local listener = listener_with()
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), fake_stream())

	fibers.run(function ()
		assert(listener:_admit_context(ctx))
		local got, err = fibers.perform(listener:accept_op())
		eq(got, ctx)
		eq(err, nil)
		listener:terminate('done')
	end)
end

function M.test_listener_accept_queue_overflow_terminates_context()
	local terminated_reason
	local listener = listener_with {
		max_accept_queue = 0,
		context_terminator = function (_, reason) terminated_reason = reason end,
	}
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), fake_stream())
	local ok1, err = listener:_admit_context(ctx)
	eq(ok1, nil)
	eq(err, 'accept_queue_full')
	eq(terminated_reason, 'accept_queue_full')
	listener:terminate('done')
end

function M.test_listener_terminate_wakes_accept_waiter()
	local listener = listener_with()

	fibers.run(function (scope)
		local got, err
		assert(scope:spawn(function ()
			got, err = fibers.perform(listener:accept_op())
		end))
		yield_many(3)
		listener:terminate('closed')
		yield_many(3)
		eq(got, nil)
		eq(err, 'closed')
	end)
end

function M.test_http_context_stream_ops_run_on_command_loop()
	local listener = listener_with()
	local stream = fake_stream()
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), stream)

	fibers.run(function (scope)
		local ok_write, err
		assert(scope:spawn(function ()
			ok_write, err = fibers.perform(ctx:write_chunk_op('abc', true))
		end))
		yield_many(3)
		ok(ctx:_drain_one_for_test(), 'command should be queued')
		yield_many(3)
		eq(ok_write, true)
		eq(err, nil)
		eq(stream.calls[1][1], 'write_chunk')
		eq(stream.calls[1][2], 'abc')
		eq(stream.calls[1][3], true)
		eq(stream.calls[1][4], nil)
		ctx:terminate('done')
		listener:terminate('done')
	end)
end

function M.test_http_context_read_helpers_preserve_http_semantics()
	local listener = listener_with()
	local stream = fake_stream()
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), stream)

	fibers.run(function (scope)
		local body
		assert(scope:spawn(function ()
			body = fibers.perform(ctx:read_body_as_string_op())
		end))
		yield_many(3)
		ok(ctx:_drain_one_for_test())
		yield_many(3)
		eq(body, 'body')
		eq(stream.calls[1][1], 'body')
		eq(stream.calls[1][2], nil)
		ctx:terminate('done')
		listener:terminate('done')
	end)
end

function M.test_http_context_stream_ops_pass_intra_stream_timeout()
	local listener = listener_with { intra_stream_timeout = 0.25 }
	local stream = fake_stream()
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), stream)

	fibers.run(function (scope)
		assert(scope:spawn(function () fibers.perform(ctx:read_chunk_op()) end))
		yield_many(3)
		ok(ctx:_drain_one_for_test())
		yield_many(3)
		eq(stream.calls[1][1], 'chunk')
		eq(stream.calls[1][2], 0.25, 'server context should pass intra_stream_timeout to lua-http stream read')
		ctx:terminate('done')
		listener:terminate('done')
	end)
end

function M.test_losing_stream_command_is_abandoned_and_not_run()
	local listener = listener_with()
	local stream = fake_stream()
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), stream)
	local ran = false
	local aborted = false

	fibers.run(function ()
		local which = fibers.perform(fibers.named_choice {
			winner = fibers.always('now'),
			cmd = ctx:run_stream_op('loser', function () ran = true; return true end, {
				on_abort = function () aborted = true end,
			}),
		})
		eq(which, 'winner')
		ok(aborted, 'abort hook should run')
		ctx:_drain_one_for_test()
		ok(not ran, 'abandoned command should not run')
		ctx:terminate('done')
		listener:terminate('done')
	end)
end

function M.test_losing_active_stream_command_terminates_context()
	local terminated_reason
	local listener = listener_with {
		context_terminator = function (_, reason) terminated_reason = reason end,
	}
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), fake_stream())
	local active = false
	local release = false

	fibers.run(function (scope)
		local waiter = assert(scope:child())
		assert(waiter:spawn(function ()
			fibers.perform(ctx:run_stream_op('active_loser', function ()
				active = true
				while not release do runtime.yield() end
				return true
			end))
		end))

		assert(scope:spawn(function () ctx:_drain_one_for_test() end))
		yield_until(function () return active end, 'stream command should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		eq(terminated_reason, 'aborted')
		ok(ctx:is_closed(), 'active command abort should close the context')
		release = true
		listener:terminate('done')
	end)
end

function M.test_losing_active_write_command_terminates_context()
	local terminated_reason
	local stream = fake_stream()
	stream.write_chunk = function ()
		stream.write_active = true
		while not stream.terminated do runtime.yield() end
		return true
	end
	local listener = listener_with {
		context_terminator = function (s, reason)
			terminated_reason = reason
			s.terminated = true
		end,
	}
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), stream)

	fibers.run(function (scope)
		local waiter = assert(scope:child())
		assert(waiter:spawn(function ()
			fibers.perform(ctx:write_chunk_op('payload', false))
		end))

		assert(scope:spawn(function () ctx:_drain_one_for_test() end))
		yield_until(function () return stream.write_active end, 'write command should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		eq(terminated_reason, 'aborted')
		ok(ctx:is_closed(), 'active write abort should close the context')
		listener:terminate('done')
	end)
end

function M.test_context_terminate_wakes_pending_stream_command()
	local listener = listener_with()
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), fake_stream())

	fibers.run(function (scope)
		local result, err
		assert(scope:spawn(function ()
			result, err = fibers.perform(ctx:run_stream_op('pending', function () return 'late' end))
		end))
		yield_many(3)
		ctx:terminate('gone')
		yield_many(3)
		eq(result, nil)
		eq(err, 'gone')
		listener:terminate('done')
	end)
end

function M.test_listener_terminate_terminates_open_contexts_and_server()
	local server = fake_server()
	local terminated = 0
	local listener = listener_with {
		server = server,
		context_terminator = function () terminated = terminated + 1 end,
	}
	local ctx = lua_http._new_context_for_test(listener, server, fake_stream())
	assert(listener:_admit_context(ctx))
	listener:terminate('service_down')
	ok(server.closed, 'server close should be called')
	eq(terminated, 1)
	ok(ctx:is_closed(), 'context should be closed')
end


function M.test_listener_terminate_does_not_terminate_accepted_context_after_transfer()
	local server = fake_server()
	local terminated = 0
	local listener = listener_with {
		server = server,
		context_terminator = function () terminated = terminated + 1 end,
	}
	local ctx = lua_http._new_context_for_test(listener, server, fake_stream())

	fibers.run(function ()
		assert(listener:_admit_context(ctx))
		local got = fibers.perform(listener:accept_op())
		eq(got, ctx)

		listener:terminate('listener_down')
		ok(server.closed, 'server close should be called')
		eq(terminated, 0)
		ok(not ctx:is_closed(), 'accepted context should be owned by the caller after accept')
		ctx:terminate('request_done')
	end)
end

function M.test_listener_listen_op_runs_via_driver()
	local server = fake_server()
	local ctl = {
		q = {},
		wrap = function (self, fn) self.q[#self.q+1] = fn end,
		step = function (self) local fn = table.remove(self.q, 1); if fn then fn() end; return true end,
		pollfd = function () return nil end,
		events = function () return '' end,
		timeout = function () return nil end,
	}
	local drv = assert(driver_mod.new { controller = ctl })
	local listener = listener_with { server = server, driver = drv }

	fibers.run(function (scope)
		assert(drv:start(scope))
		local ok_listen = fibers.perform(listener:listen_op())
		eq(ok_listen, true)
		eq(server.listened, true)
		listener:terminate('done')
		drv:terminate('done')
	end)
end


function M.test_listener_start_can_target_started_parent_scope_from_child_scope()
	local listener = listener_with()

	fibers.run(function (parent)
		local child = assert(parent:child())
		local started, start_err

		assert(child:spawn(function ()
			started, start_err = listener:start(parent)
		end))

		yield_many(3)
		eq(started, true)
		eq(start_err, nil)
		listener:terminate('done')
	end)
end


function M.test_onstream_admission_does_not_call_service_hook_synchronously()
	local called = 0
	local listener = listener_with {
		on_context = function ()
			called = called + 1
			error('service hook must not run from the backend onstream path', 0)
		end,
	}
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), fake_stream())

	local admitted, err = listener:_admit_context(ctx)
	eq(admitted, true)
	eq(err, nil)
	eq(called, 0, 'backend context admission must only wake a Fibers-owned event source')
	listener:terminate('done')
end

return M
