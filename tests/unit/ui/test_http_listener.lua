-- tests/unit/ui/test_http_listener.lua

local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'
local pulse = require 'fibers.pulse'
local run_fibers = require 'tests.support.run_fibers'
local listener_mod = require 'services.ui.http.listener'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local FakeContext = {}
FakeContext.__index = FakeContext

local function make_ctx(spec)
	spec = spec or {}
	return setmetatable({
		_id = spec.id,
		_method = spec.method or 'GET',
		_path = spec.path or '/',
		terminated = false,
		terminate_reason = nil,
	}, FakeContext)
end

function FakeContext:id() return self._id end
function FakeContext:method() return self._method end
function FakeContext:path() return self._path end
function FakeContext:terminate(reason)
	self.terminated = true
	self.terminate_reason = reason
	return true, nil
end
local FakeListener = {}
FakeListener.__index = FakeListener

local function fake_listener()
	local tx, rx = mailbox.new(16, { full = 'reject_newest' })
	local accept_started = pulse.new()
	return setmetatable({
		_tx = tx,
		_rx = rx,
		_accept_started = accept_started,
		_accept_seen = accept_started:version(),
		_terminated = false,
		_reason = nil,
	}, FakeListener)
end

function FakeListener:accept_now(ctx)
	return self._tx:send(ctx)
end

function FakeListener:accept_op()
	self._accept_started:signal()
	return self._rx:recv_op():wrap(function (ctx)
		if ctx == nil then return nil, tostring(self._rx:why() or 'closed') end
		return ctx, nil
	end)
end

function FakeListener:terminate(reason)
	if self._terminated then return true, nil end
	self._terminated = true
	self._reason = reason or 'closed'
	self._tx:close(self._reason)
	return true, nil
end
function FakeListener:terminated() return self._terminated end
function FakeListener:accept_started_op() return self._accept_started:changed_op(self._accept_seen) end

local function recv_kind(rx, kind)
	while true do
		local ev = fibers.perform(rx:recv_op())
		assert_not_nil(ev, 'event stream closed before '..kind)
		if ev.kind == kind then return ev end
	end
end

function tests.test_accept_transfers_context_to_request_scope_and_reports_started_done()
	run_fibers.run(function (scope)
		local done_tx, done_rx = mailbox.new(16, { full = 'reject_newest' })
		local listener = fake_listener()
		local seen_in_request = false

		local ok, err = scope:spawn(function (s)
			listener_mod.run(s, {
				listener = listener,
				done_tx = done_tx,
				run_request = function (_request_scope, ctx)
					seen_in_request = true
					assert_eq(ctx:method(), 'GET')
					assert_eq(ctx:path(), '/status')
					return { status = 'ok' }
				end,
			})
		end)
		assert_true(ok, err)

		local raw = make_ctx({ id = 'req-1', method = 'GET', path = '/status' })
		assert_true(listener:accept_now(raw))

		local started = recv_kind(done_rx, 'http_request_started')
		assert_eq(started.request_id, 'req-1')
		assert_eq(started.active_requests, 1)

		local done = recv_kind(done_rx, 'http_request_done')
		assert_eq(done.request_id, 'req-1')
		assert_eq(done.status, 'ok')
		assert_eq(done.active_requests, 0)
		assert_true(seen_in_request)
		assert_true(raw.terminated)
	end)
end

function tests.test_listener_can_obtain_handle_from_http_capability_sdk()
	run_fibers.run(function (scope)
		local done_tx, done_rx = mailbox.new(16, { full = 'reject_newest' })
		local listener = fake_listener()
		local call_topic
		local call_payload
		local conn = {
			call_op = function(_, topic, payload)
				call_topic = topic
				call_payload = payload
				return fibers.always({ listener = listener }, nil)
			end,
		}

		local ok, err = scope:spawn(function (s)
			listener_mod.run(s, {
				conn = conn,
				listen = { host = '127.0.0.1', port = 8080 },
				done_tx = done_tx,
				run_request = function () return { status = 'ok' } end,
			})
		end)
		assert_true(ok, err)

		local raw = make_ctx({ id = 'req-cap', method = 'GET', path = '/' })
		assert_true(listener:accept_now(raw))
		local started = recv_kind(done_rx, 'http_request_started')
		assert_eq(started.request_id, 'req-cap')
		assert_not_nil(call_topic)
		assert_eq(call_topic[1], 'cap')
		assert_eq(call_topic[2], 'http')
		assert_eq(call_topic[3], 'main')
		assert_eq(call_topic[4], 'rpc')
		assert_eq(call_topic[5], 'listen')
		assert_eq(call_payload.host, '127.0.0.1')
	end)
end

function tests.test_overloaded_listener_rejects_without_request_scope()
	run_fibers.run(function (scope)
		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local listener = fake_listener()
		local ran_request = false

		local ok, err = scope:spawn(function (s)
			listener_mod.run(s, {
				listener = listener,
				done_tx = done_tx,
				max_active_requests = 0,
				overload_reason = 'too_many_requests',
				run_request = function ()
					ran_request = true
					return { status = 'unexpected' }
				end,
			})
		end)
		assert_true(ok, err)

		local raw = make_ctx({ id = 'req-2', method = 'GET', path = '/' })
		assert_true(listener:accept_now(raw))

		local rejected = recv_kind(done_rx, 'http_request_rejected')
		assert_eq(rejected.request_id, 'req-2')
		assert_eq(rejected.reason, 'too_many_requests')
		assert_eq(rejected.active_requests, 0)
		assert_eq(rejected.max_active_requests, 0)
		assert_true(rejected.cleanup_ok)
		assert_true(raw.terminated)
		assert_eq(raw.terminate_reason, 'too_many_requests')
		assert_eq(ran_request, false)
	end)
end

function tests.test_request_scope_finaliser_owns_context_on_failure()
	run_fibers.run(function (scope)
		local done_tx, done_rx = mailbox.new(8, { full = 'reject_newest' })
		local listener = fake_listener()

		local ok, err = scope:spawn(function (s)
			listener_mod.run(s, {
				listener = listener,
				done_tx = done_tx,
				run_request = function () error('boom', 0) end,
			})
		end)
		assert_true(ok, err)

		local raw = make_ctx({ id = 'req-3', method = 'GET', path = '/boom' })
		assert_true(listener:accept_now(raw))

		local done = recv_kind(done_rx, 'http_request_done')
		assert_eq(done.request_id, 'req-3')
		assert_eq(done.status, 'failed')
		assert_eq(done.primary, 'boom')
		assert_true(raw.terminated)
		assert_eq(raw.terminate_reason, 'boom')
	end)
end

function tests.test_listener_finaliser_terminates_http_listener_handle()
	run_fibers.run(function (scope)
		local listener = fake_listener()
		local owner, cerr = scope:child()
		assert_not_nil(owner, cerr)
		local ok, err = owner:spawn(function (s)
			listener_mod.run(s, {
				listener = listener,
				run_request = function () return { status = 'ok' } end,
			})
		end)
		assert_true(ok, err)

		local _, wait_err = fibers.perform(listener:accept_started_op())
		assert_eq(wait_err, nil)

		owner:cancel('test_cancel')
		fibers.perform(owner:join_op())
		assert_true(listener:terminated())
	end)
end

return tests
