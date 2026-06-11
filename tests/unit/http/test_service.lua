local fibers = require 'fibers'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'
local bus    = require 'bus'

local http_service = require 'services.http.service'
local sdk_mod      = require 'services.http.sdk'
local listener_owner = require 'services.http.listener_owner'
local lua_http      = require 'services.http.transport.lua_http'
local public_ws     = require 'services.http.websocket'
local driver_mod    = require 'services.http.transport.cqueues_driver'
local operation_owner = require 'services.http.operation_owner'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

local function yield_many(n)
	for _ = 1, n do runtime.yield() end
end


local function yield_until(pred, msg)
	for _ = 1, 80 do
		if pred() then return true end
		runtime.yield()
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
		started = false,
		terminated = nil,
		start = function (self) self.started = true; return true end,
		terminate = function (self, reason) self.terminated = reason or true; return true end,
		run_op = function (_, _, fn) return fibers.guard(function () return fibers.always(fn()) end) end,
	}
end

function M.test_service_retains_capability_metadata_and_status()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local drv = fake_driver()
		local svc = ok(http_service.open_handle(root, { driver = drv, id = 'main' }))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local ref = sdk_mod.new_ref(user, 'main')
		local rep = ok(fibers.perform(ref:status_op()))
		ok(rep.status.ready, 'service should report ready')
		svc:terminate('done')
		eq(drv.terminated, 'done')
	end)
end

function M.test_non_local_handle_returning_call_is_rejected_before_backend_work()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local drv = fake_driver()
		local svc = ok(http_service.open_handle(root, { driver = drv, id = 'main' }))
		local remote = b:connect({ origin_base = { kind = 'local', link_id = 'fabric-link' } })
		local ref = sdk_mod.new_ref(remote, 'main')
		local reply, err = fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0 }))
		eq(reply, nil)
		eq(err, 'not_local')
		svc:terminate('done')
	end)
end


function M.test_registry_callbacks_do_not_mutate_model_until_coordinator_receives_event()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		yield_many(4)
		eq(svc:stats().active_listeners, 0)
		eq(svc._emit, nil, 'legacy direct reducer ingress should not exist')

		local real_tx = svc._event_tx
		local captured = {}
		svc._event_tx = {
			send_op = function (_, ev)
				captured[#captured + 1] = ev
				return fibers.always(true, nil)
			end,
		}
		local id = ok(svc._registry:register('listener', { terminate = function () return true end }, { generation = svc._generation }))
		eq(svc:stats().active_listeners, 0, 'registry callback must only enqueue an event')
		eq(captured[1].kind, 'listener_registered')
		svc._event_tx = real_tx
		ok(svc:_submit_event(captured[1]))
		yield_many(4)
		eq(svc:stats().active_listeners, 1)
		svc._registry:remove(id, 'done')
		yield_many(4)
		eq(svc:stats().active_listeners, 0)
		svc:terminate('done')
	end)
end

function M.test_model_fields_are_recomputed_from_identity_records_and_duplicate_termination_is_idempotent()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		yield_many(4)

		ok(svc:_submit_event({ kind = 'listener_registered', handle_id = 'l1', generation = 1 }))
		ok(svc:_submit_event({ kind = 'listener_registered', handle_id = 'l2', generation = 1 }))
		ok(svc:_submit_event({ kind = 'listener_terminated', handle_id = 'l1', generation = 1 }))
		ok(svc:_submit_event({ kind = 'listener_terminated', handle_id = 'l1', generation = 1 }))
		yield_many(8)
		eq(svc:stats().active_listeners, 1, 'duplicate termination must not decrement a derived count twice')

		ok(svc:_submit_event({ kind = 'exchange_registered', handle_id = 'e1', generation = 1 }))
		ok(svc:_submit_event({ kind = 'websocket_registered', handle_id = 'w1', generation = 1 }))
		ok(svc:_submit_event({ kind = 'context_admitted', listener_id = 'l2', context_id = 'c1', generation = 1 }))
		yield_many(8)
		local snap = svc:stats()
		eq(snap.active_listeners, 1)
		eq(snap.active_exchanges, 1)
		eq(snap.active_websockets, 1)
		eq(snap.active_contexts, 1)
		svc:terminate('done')
	end)
end

function M.test_stale_generation_events_are_ignored()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		yield_many(4)

		ok(svc:_submit_event({ kind = 'listener_registered', handle_id = 'l1', generation = 1 }))
		yield_many(4)
		eq(svc:stats().active_listeners, 1)
		ok(svc:_submit_event({ kind = 'listener_terminated', handle_id = 'l1', generation = 2 }))
		yield_many(4)
		eq(svc:stats().active_listeners, 1, 'stale handle generation must not terminate the live record')

		svc._state.operations.op_live = { operation_id = 'op_live', generation = 1, operation = 'exchange', state = 'running' }
		ok(svc:_submit_event({ kind = 'http_operation_done', operation_id = 'op_live', operation = 'exchange', generation = 2, status = 'ok', result = {} }))
		yield_many(4)
		eq(svc:stats().completed_exchanges, 0, 'stale operation completion must not be counted')
		svc:terminate('done')
	end)
end

function M.test_cap_request_received_then_service_shutdown_finalises_request_owner()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		local failed
		local req = {
			payload = {},
			origin = { kind = 'local' },
			reply = function () return true end,
			fail = function (_, reason) failed = reason; return true end,
		}
		local request_id, owner = svc:_next_request_identity('status', req)
		ok(svc:_submit_event({ kind = 'cap_request_received', verb = 'status', req = req, request_id = request_id, owner = owner, generation = svc._generation }))
		svc:terminate('service_shutdown')
		eq(failed, 'service_shutdown')
	end)
end

function M.test_event_queue_overflow_for_completion_fails_observing_service()
	fibers.run(function (scope)
		local child = ok(scope:child())
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })
		ok(child:spawn(function ()
			local b = bus.new()
			local root = b:connect({ origin_base = { kind = 'local' } })
			local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main', event_queue_len = 1 }))
			return fibers.perform(tx:send_op(svc))
		end))
		local svc = ok(fibers.perform(rx:recv_op()))
		-- Replace the event sender with a would-block sender. This exercises the
		-- same required-admission path as a full bounded queue without relying on
		-- scheduler timing around a live coordinator.
		svc._event_tx = {
			send_op = function () return fibers.never() end,
		}
		local ok_report, err = svc:_submit_event({ kind = 'http_operation_done', operation_id = 'op-missing', generation = 1, status = 'ok' }, 'http_operation_done_report_failed', { fatal = true })
		eq(ok_report, nil)
		ok(tostring(err):match('http_operation_done_report_failed'), 'overflow should use the completion report label')
		ok(svc._event_admission_failure and tostring(svc._event_admission_failure):match('http_operation_done_report_failed'))
		local st, _rep, primary = fibers.perform(child:join_op())
		eq(st, 'failed')
		ok(tostring(primary):match('http_operation_done_report_failed'))
	end)
end


function M.test_bus_request_abandonment_cancels_admitted_http_operation()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		yield_many(4)

		local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })
		local req = {
			payload = { method = 'GET', url = 'http://example.invalid/' },
			origin = { kind = 'local' },
			reply = function () error('abandoned request must not be replied to', 0) end,
			fail = function () error('abandoned request must not be failed visibly', 0) end,
			done_op = function ()
				return done_rx:recv_op():wrap(function (ev)
					return ev.status, ev.value, ev.err
				end)
			end,
		}
		local request_id, owner = svc:_next_request_identity('exchange', req)
		svc._state.requests[request_id] = { request_id = request_id, verb = 'exchange', owner = owner, state = 'received', generation = svc._generation }

		ok(operation_owner.start(svc, 'exchange', req, request_id, owner, function ()
			fibers.perform(sleep.sleep_op(10.0))
			return { ok = true }
		end))

		local operation_id
		for id, rec in pairs(svc._state.operations) do
			if rec.request_id == request_id then operation_id = id end
		end
		ok(operation_id, 'expected operation identity')

		ok(done_tx:send({ status = 'abandoned', err = 'caller_timeout' }))
		yield_until(function ()
			local rec = svc._state.operations[operation_id]
			return rec and rec.state == 'completed'
		end, 'operation should complete after caller abandonment')

		local rec = svc._state.operations[operation_id]
		eq(rec.status, 'cancelled')
		eq(rec.primary, 'caller_timeout')
		local reqrec = svc._state.requests[request_id]
		eq(reqrec.state, 'cancelled')
		eq(reqrec.reason, 'caller_timeout')
		eq(svc._owned_requests[request_id], nil)
		ok(owner:done(), 'owner should be locally abandoned')

		svc:terminate('done')
	end)
end

function M.test_http_sdk_uses_compositional_timeout_by_default()
	local seen_opts
	local ref = sdk_mod.new_ref({
		call_op = function (_, _topic, _args, opts)
			seen_opts = opts
			return fibers.always('ok')
		end,
	}, 'main')

	fibers.run(function ()
		local v = fibers.perform(ref:exchange_op({ method = 'GET', url = 'http://example.invalid/' }))
		eq(v, 'ok')
	end)

	ok(seen_opts, 'expected SDK to pass call opts')
	eq(seen_opts.timeout, false)
end

function M.test_service_shutdown_terminates_registry_handles_and_finalises_unresolved_requests()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		local terminated
		local id = ok(svc._registry:register('exchange', { terminate = function (_, reason) terminated = reason; return true end }, { generation = svc._generation }))
		yield_many(4)
		local failed
		local req = { fail = function (_, reason) failed = reason; return true end }
		local request_id, owner = svc:_next_request_identity('exchange', req)
		svc._state.requests[request_id] = { request_id = request_id, verb = 'exchange', owner = owner, state = 'received' }
		svc:terminate('shutdown')
		eq(terminated, 'shutdown')
		eq(failed, 'shutdown')
		eq(svc._registry:get(id), nil)
	end)
end


function M.test_context_transfer_keeps_context_active_after_listener_termination_until_context_terminates()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		yield_many(4)
		ok(svc:_submit_event({ kind = 'listener_registered', handle_id = 'l1', generation = 1 }))
		ok(svc:_submit_event({ kind = 'context_admitted', listener_id = 'l1', context_id = 'c1', generation = 1 }))
		ok(svc:_submit_event({ kind = 'context_transferred', listener_id = 'l1', context_id = 'c1', generation = 1 }))
		ok(svc:_submit_event({ kind = 'listener_terminated', handle_id = 'l1', generation = 1, reason = 'listener_closed' }))
		yield_many(8)
		local snap = svc:stats()
		eq(snap.active_listeners, 0)
		eq(snap.active_contexts, 1, 'transferred context should remain active after listener termination')
		ok(svc:_submit_event({ kind = 'context_terminated', listener_id = 'l1', context_id = 'c1', generation = 1, reason = 'request_done' }))
		yield_many(4)
		eq(svc:stats().active_contexts, 0)
		svc:terminate('done')
	end)
end

local function fake_polling_driver()
	local cond = require 'fibers.cond'
	local changed = cond.new()
	local drv = {
		started = false,
		terminated = nil,
	}
	function drv:start() self.started = true; return true end
	function drv:terminate(reason)
		self.terminated = reason or true
		changed:signal()
		return true
	end
	function drv:run_op(_, fn) return fibers.guard(function () return fibers.always(fn()) end) end
	function drv:pollable_step_op()
		return changed:wait_op():wrap(function ()
			if self.terminated then return nil, self.terminated end
			return true
		end)
	end
	function drv:poke() changed:signal(); return true end
	return drv
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

local function request_module(body_text, counters)
	counters = counters or {}
	return {
		new_from_uri = function (uri)
			counters.request_new_from_uri = (counters.request_new_from_uri or 0) + 1
			return {
				uri = uri,
				headers = {
					set = {},
					upsert = function (self, k, v) self.set[k] = v end,
					append = function (self, k, v) self.set[k] = v end,
				},
				go = function (self)
					local chunks = { body_text or ('body for ' .. self.uri) }
					local i = 0
					return fake_headers(204), {
						get_next_chunk = function () i = i + 1; return chunks[i] end,
						shutdown = function () return true end,
					}
				end,
			}
		end,
	}
end

local function websocket_module(counters)
	counters = counters or {}
	return {
		new_from_uri = function (uri)
			counters.websocket_new_from_uri = (counters.websocket_new_from_uri or 0) + 1
			return {
				uri = uri,
				connect = function (self) self.connected = true; return true end,
				send = function () return true end,
				receive = function () return nil, 'closed' end,
				close = function () return true end,
			}
		end,
	}
end

local function http_server_success(counters)
	counters = counters or {}
	return {
		listen = function (opts)
			counters.server_listen_constructed = (counters.server_listen_constructed or 0) + 1
			return {
				_opts = opts,
				listen = function (self)
					self.listen_called = true
					counters.server_listen_called = (counters.server_listen_called or 0) + 1
					return true
				end,
				step = function () return true end,
				close = function (self)
					self.closed = true
					counters.server_closed = (counters.server_closed or 0) + 1
					return true
				end,
				localname = function () return '127.0.0.1', 12345 end,
			}
		end,
	}
end


local function fake_stream_for_context()
	local stream
	stream = {
		terminated = false,
		calls = {},
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
		shutdown = function () error('context termination must not use graceful stream shutdown', 0) end,
		get_headers = function () return { ':method', 'GET' } end,
		get_next_chunk = function () return nil end,
		write_headers = function () return true end,
		write_chunk = function () return true end,
	}
	return stream
end

local function event_seen(events, kind, pred)
	for _, ev in ipairs(events or {}) do
		if ev.kind == kind and (not pred or pred(ev)) then return ev end
	end
	return nil
end

function M.test_backend_failure_terminates_service_owned_handles()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		yield_many(4)

		local terminated = {}
		local function handle(name)
			return {
				terminate = function (_, reason)
					terminated[name] = reason or true
					return true
				end,
				close_op = function () error('graceful close_op must not be used by registry termination', 0) end,
			}
		end

		svc._registry:register('listener', handle('listener'), { id = 'l1', generation = svc._generation })
		svc._registry:register('exchange', handle('exchange'), { id = 'e1', generation = svc._generation })
		svc._registry:register('websocket', handle('websocket'), { id = 'w1', generation = svc._generation })
		yield_many(8)
		local before = svc:stats()
		eq(before.active_listeners, 1)
		eq(before.active_exchanges, 1)
		eq(before.active_websockets, 1)

		ok(svc:_submit_event({ kind = 'backend_failed', reason = 'backend_boom', generation = svc._generation }))
		yield_many(12)
		local after = svc:stats()
		eq(after.backend, 'failed')
		eq(after.ready, false)
		eq(after.last_error, 'backend_boom')
		eq(after.active_listeners, 0)
		eq(after.active_exchanges, 0)
		eq(after.active_websockets, 0)
		eq(terminated.listener, 'backend_boom')
		eq(terminated.exchange, 'backend_boom')
		eq(terminated.websocket, 'backend_boom')
		svc:terminate('done')
	end)
end

function M.test_listener_setup_failure_leaves_no_live_ownership()
	fibers.run(function ()
		local counters = {}
		local failing_server = {
			listen = function ()
				counters.constructed = (counters.constructed or 0) + 1
				return {
					listen = function () counters.listen_called = (counters.listen_called or 0) + 1; return nil, 'listen_failed' end,
					close = function () counters.closed = (counters.closed or 0) + 1; return true end,
					step = function () return true end,
				}
			end,
		}
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_polling_driver(), id = 'main', http_server = failing_server }))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local ref = sdk_mod.new_ref(user, 'main')

		local reply, err = fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0 }))
		eq(reply, nil)
		eq(err, 'listen_failed')
		yield_many(12)
		eq(counters.constructed, 1)
		eq(counters.listen_called, 1)
		eq(counters.closed, 1)
		eq(svc:stats().active_listeners, 0)
		eq(next(svc._registry:snapshot()), nil, 'failed listener setup must leave no active registry record')
		svc:terminate('done')
	end)
end

function M.test_handle_returning_rpcs_return_public_wrappers()
	fibers.run(function ()
		local counters = {}
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success(counters),
			request_module = request_module('body', counters),
			websocket_module = websocket_module(counters),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local ref = sdk_mod.new_ref(user, 'main')

		local listen_reply = ok(fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0 })))
		local exchange_reply = ok(fibers.perform(ref:open_exchange_op({ uri = 'http://example.test/', method = 'GET' })))
		local websocket_reply = ok(fibers.perform(ref:connect_ws_op({ uri = 'ws://example.test/ws' })))

		local listener_mod = require 'services.http.listener'
		local exchange_mod = require 'services.http.exchange'
		local websocket_mod = require 'services.http.websocket'
		eq(getmetatable(listen_reply.listener), listener_mod.HttpListener, 'listen should return public HttpListener wrapper')
		eq(getmetatable(exchange_reply.exchange), exchange_mod.HttpExchange, 'open_exchange should return public HttpExchange wrapper')
		eq(getmetatable(websocket_reply.websocket), websocket_mod.ClientWebSocket, 'connect_ws should return public ClientWebSocket wrapper')
		ok(not tostring(getmetatable(listen_reply.listener)):match('transport'), 'listener wrapper should not expose transport type')
		ok(not tostring(getmetatable(exchange_reply.exchange)):match('transport'), 'exchange wrapper should not expose transport type')
		ok(not tostring(getmetatable(websocket_reply.websocket)):match('transport'), 'websocket wrapper should not expose transport type')
		svc:terminate('done')
	end)
end

function M.test_each_local_handle_rpc_rejects_non_local_before_backend_admission()
	fibers.run(function ()
		local counters = {}
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success(counters),
			request_module = request_module('body', counters),
			websocket_module = websocket_module(counters),
		}))
		local remote = b:connect({ origin_base = { kind = 'local', link_id = 'fabric-link' } })
		local ref = sdk_mod.new_ref(remote, 'main')

		local listen_reply, listen_err = fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0 }))
		local exchange_reply, exchange_err = fibers.perform(ref:open_exchange_op({ uri = 'http://example.test/', method = 'GET' }))
		local ws_reply, ws_err = fibers.perform(ref:connect_ws_op({ uri = 'ws://example.test/ws' }))
		eq(listen_reply, nil)
		eq(exchange_reply, nil)
		eq(ws_reply, nil)
		eq(listen_err, 'not_local')
		eq(exchange_err, 'not_local')
		eq(ws_err, 'not_local')
		eq(counters.server_listen_constructed or 0, 0, 'non-local listen must reject before backend admission')
		eq(counters.request_new_from_uri or 0, 0, 'non-local open_exchange must reject before request construction')
		eq(counters.websocket_new_from_uri or 0, 0, 'non-local connect_ws must reject before websocket construction')
		eq(svc:stats().rejected_requests, 3)
		svc:terminate('done')
	end)
end


function M.test_initial_retained_status_is_not_available_before_backend_ready_event_is_reduced()
	fibers.run(function ()
		local topics = require 'services.http.topics'
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))

		local view = root:retained_view(topics.status('main'))
		local msg = ok(view:get(topics.status('main')), 'status should be retained immediately')
		eq(msg.payload.available, false, 'cap status must not advertise availability before backend_ready is reduced')
		eq(msg.payload.state, 'starting')
		svc:terminate('done')
	end)
end

function M.test_listener_owner_reports_identity_completion_when_listener_runtime_ends()
	fibers.run(function ()
		local counters = {}
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success(counters),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local ref = sdk_mod.new_ref(user, 'main')

		local rep = ok(fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0 })))
		local listener = ok(rep.listener)
		local handle_id = ok(rep.handle_id)
		listener:terminate('listener_done_for_test')
		yield_many(12)

		local saw_done = false
		for _, ev in ipairs(svc:events()) do
			if ev.kind == 'listener_done' and ev.handle_id == handle_id then
				saw_done = true
				eq(ev.generation, svc._generation)
				eq(ev.status, 'ok')
			end
		end
		ok(saw_done, 'listener owner scope should report an identity-bearing completion')
		svc:terminate('done')
	end)
end


function M.test_onstream_context_admission_emits_service_event_without_reducing_in_callback()
	fibers.run(function ()
		local counters = {}
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success(counters),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local ref = sdk_mod.new_ref(user, 'main')
		local rep = ok(fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0 })))
		local listener = ok(rep.listener)
		local raw_listener = ok(listener:_raw_listener())
		local raw_ctx = lua_http._new_context_for_test(raw_listener, raw_listener:_raw_server_for_test(), fake_stream_for_context())

		local admitted, err = raw_listener:_admit_context(raw_ctx)
		eq(admitted, true)
		eq(err, nil)
		eq(svc:stats().active_contexts, 0, 'onstream admission must enqueue, not run the service reducer synchronously')

		yield_many(8)
		eq(svc:stats().active_contexts, 1, 'queued, unaccepted context should be counted as listener-owned after coordinator observes admission')
		ok(event_seen(svc:events(), 'context_admitted', function (ev)
			return ev.listener_id == rep.handle_id and ev.context_id == raw_ctx:id()
		end), 'context_admitted event should carry listener/context identity')
		ok(not event_seen(svc:events(), 'context_transferred', function (ev)
			return ev.context_id == raw_ctx:id()
		end), 'onstream admission must not imply caller ownership transfer')
		svc:terminate('done')
	end)
end

function M.test_unaccepted_context_is_listener_owned_until_accept()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success({}),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local rep = ok(fibers.perform(sdk_mod.new_ref(user, 'main'):listen_op({ host = '127.0.0.1', port = 0 })))
		local raw_listener = rep.listener:_raw_listener()
		local raw_ctx = lua_http._new_context_for_test(raw_listener, raw_listener:_raw_server_for_test(), fake_stream_for_context())
		ok(raw_listener:_admit_context(raw_ctx))
		yield_many(8)

		local snap = svc:stats()
		eq(snap.active_contexts, 1)
		local rec = snap.handles['ctx' .. tostring(raw_ctx:id())]
		ok(rec, 'unaccepted context should have a registry record')
		eq(rec.kind, 'context')
		eq(rec.owner, 'listener')
		eq(rec.state, 'registered')

		local accepted = ok(fibers.perform(rep.listener:accept_op()))
		eq(accepted:id(), raw_ctx:id())
		yield_many(8)
		local after = svc:stats().handles['ctx' .. tostring(raw_ctx:id())]
		ok(after, 'accepted context should remain registered as a service shutdown backstop')
		eq(after.owner, 'caller_after_handoff')
		eq(after.state, 'transferred')
		svc:terminate('done')
	end)
end

function M.test_listener_termination_terminates_unaccepted_context_and_emits_context_terminated()
	fibers.run(function ()
		local terminated_reason
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success({}),
			context_terminator = function (_, reason) terminated_reason = reason end,
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local rep = ok(fibers.perform(sdk_mod.new_ref(user, 'main'):listen_op({ host = '127.0.0.1', port = 0 })))
		local raw_listener = rep.listener:_raw_listener()
		local raw_ctx = lua_http._new_context_for_test(raw_listener, raw_listener:_raw_server_for_test(), fake_stream_for_context())
		ok(raw_listener:_admit_context(raw_ctx))
		yield_many(8)

		rep.listener:terminate('listener_closed')
		yield_many(12)
		ok(raw_ctx:is_closed(), 'unaccepted context should be terminated with its listener')
		eq(terminated_reason, 'listener_closed')
		ok(event_seen(svc:events(), 'context_terminated', function (ev)
			return ev.context_id == raw_ctx:id() and ev.reason == 'listener_closed'
		end), 'listener-owned context termination should emit context_terminated')
		eq(svc:stats().active_contexts, 0)
		svc:terminate('done')
	end)
end

function M.test_accepted_context_survives_listener_termination_until_context_terminates()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success({}),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local rep = ok(fibers.perform(sdk_mod.new_ref(user, 'main'):listen_op({ host = '127.0.0.1', port = 0 })))
		local raw_listener = rep.listener:_raw_listener()
		local raw_ctx = lua_http._new_context_for_test(raw_listener, raw_listener:_raw_server_for_test(), fake_stream_for_context())
		ok(raw_listener:_admit_context(raw_ctx))
		local ctx = ok(fibers.perform(rep.listener:accept_op()))
		yield_many(8)

		rep.listener:terminate('listener_closed')
		yield_many(8)
		ok(not ctx:is_closed(), 'accepted context should be owned by caller/request scope after accept')
		eq(svc:stats().active_contexts, 1)
		ctx:terminate('request_done')
		yield_many(8)
		eq(svc:stats().active_contexts, 0)
		svc:terminate('done')
	end)
end

function M.test_cancel_listen_start_while_waiting_for_ready_cleans_up_setup_listener()
	fibers.run(function (scope)
		local closed_reason
		local server = {
			listen = function () return true end,
			close = function (_, reason) closed_reason = reason or true; return true end,
			step = function () return true end,
		}
		local drv = fake_driver()
		drv.run_op = function () return fibers.never() end
		local lifetime = ok(scope:child())
		local caller = ok(scope:child())
		local result, err
		ok(caller:spawn(function ()
			result, err = listener_owner.start({
				lifetime_scope = lifetime,
				listen_opts = { driver = drv, server = server },
				handle_id = 'listener-pending',
				generation = 1,
			})
		end))
		yield_many(8)
		caller:cancel('caller_cancelled')
		yield_many(12)
		eq(result, nil)
		ok(closed_reason ~= nil, 'cancelled listen setup should terminate the unreturned listener immediately')
		lifetime:cancel('done')
	end)
end

function M.test_server_side_websocket_upgrade_registers_and_deregisters_service_websocket_record()
	fibers.run(function (scope)
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success({}),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local rep = ok(fibers.perform(sdk_mod.new_ref(user, 'main'):listen_op({ host = '127.0.0.1', port = 0 })))
		local raw_listener = rep.listener:_raw_listener()
		local raw_ctx = lua_http._new_context_for_test(raw_listener, raw_listener:_raw_server_for_test(), fake_stream_for_context())
		ok(raw_listener:_admit_context(raw_ctx))
		local ctx = ok(fibers.perform(rep.listener:accept_op()))
		local fake_raw_ws = {
			accept = function () return true end,
			receive = function () return nil, 'closed' end,
			send = function () return true end,
			close = function () return true end,
		}
		local module = { new_from_stream = function () return fake_raw_ws end }
		local ws, werr
		ok(scope:spawn(function ()
			ws, werr = fibers.perform(public_ws.from_context_op(ctx, {}, { websocket_module = module }))
		end))
		yield_many(3)
		ok(raw_ctx:_drain_one_for_test())
		yield_many(8)
		ok(ws, werr or 'server websocket should be returned')
		eq(svc:stats().active_websockets, 1, 'server-side websocket upgrade should be visible in service summary')
		ws:terminate('ws_done')
		yield_many(8)
		eq(svc:stats().active_websockets, 0)
		svc:terminate('done')
	end)
end

function M.test_service_shutdown_terminates_server_side_upgraded_websocket()
	fibers.run(function (scope)
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success({}),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local rep = ok(fibers.perform(sdk_mod.new_ref(user, 'main'):listen_op({ host = '127.0.0.1', port = 0 })))
		local raw_listener = rep.listener:_raw_listener()
		local raw_ctx = lua_http._new_context_for_test(raw_listener, raw_listener:_raw_server_for_test(), fake_stream_for_context())
		ok(raw_listener:_admit_context(raw_ctx))
		local ctx = ok(fibers.perform(rep.listener:accept_op()))
		local fake_raw_ws = { close = function () return true end, receive = function () return nil, 'closed' end, send = function () return true end }
		local module = { new_from_stream = function () return fake_raw_ws end }
		local ws
		ok(scope:spawn(function () ws = fibers.perform(public_ws.from_context_op(ctx, {}, { websocket_module = module })) end))
		yield_many(3)
		ok(raw_ctx:_drain_one_for_test())
		yield_many(8)
		ok(ws)
		svc:terminate('service_shutdown')
		yield_many(4)
		ok(ws:is_closed(), 'service shutdown should terminate registered server-side websocket transport handles')
		eq(ws:why(), 'service_shutdown')
	end)
end


function M.test_public_context_read_cancellation_terminates_context_and_service_record()
	fibers.run(function (scope)
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success({}),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local rep = ok(fibers.perform(sdk_mod.new_ref(user, 'main'):listen_op({ host = '127.0.0.1', port = 0 })))
		local raw_listener = rep.listener:_raw_listener()
		local stream = fake_stream_for_context()
		local read_active = false
		stream.get_next_chunk = function (self)
			read_active = true
			while not self.terminated do runtime.yield() end
			return nil, 'closed'
		end
		local raw_ctx = lua_http._new_context_for_test(raw_listener, raw_listener:_raw_server_for_test(), stream)
		ok(raw_listener:_admit_context(raw_ctx))
		local ctx = ok(fibers.perform(rep.listener:accept_op()))
		yield_many(8)
		eq(svc:stats().active_contexts, 1)

		local waiter = ok(scope:child())
		ok(waiter:spawn(function () fibers.perform(ctx:read_chunk_op(1024)) end))
		local runner = ok(scope:child())
		ok(runner:spawn(function () raw_ctx:_drain_one_for_test() end))
		yield_until(function () return read_active end, 'public context read should be active')

		waiter:cancel('caller_cancelled')
		fibers.perform(waiter:join_op())
		yield_until(function () return svc:stats().active_contexts == 0 end,
			'context termination should be reported through service-owned events')
		ok(ctx:is_closed(), 'cancelling a public context read should terminate the context owner')
		eq(ctx:why(), 'aborted')
		runner:cancel('done')
		fibers.perform(runner:join_op())
		svc:terminate('done')
	end)
end

function M.test_public_server_websocket_receive_cancellation_terminates_websocket_and_registry_record()
	fibers.run(function (scope)
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = fake_polling_driver(),
			id = 'main',
			http_server = http_server_success({}),
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local rep = ok(fibers.perform(sdk_mod.new_ref(user, 'main'):listen_op({ host = '127.0.0.1', port = 0 })))
		local raw_listener = rep.listener:_raw_listener()
		local raw_ctx = lua_http._new_context_for_test(raw_listener, raw_listener:_raw_server_for_test(), fake_stream_for_context())
		ok(raw_listener:_admit_context(raw_ctx))
		local ctx = ok(fibers.perform(rep.listener:accept_op()))

		local receive_active = false
		local fake_raw_ws = {
			accept = function () return true end,
			receive = function ()
				receive_active = true
				while not raw_ctx:is_closed() do runtime.yield() end
				return nil, 'closed'
			end,
			send = function () return true end,
			close = function (self, _code, reason) self.closed_reason = reason or true; return true end,
		}
		local module = { new_from_stream = function () return fake_raw_ws end }
		local ws
		ok(scope:spawn(function () ws = fibers.perform(public_ws.from_context_op(ctx, {}, { websocket_module = module })) end))
		yield_many(3)
		ok(raw_ctx:_drain_one_for_test())
		yield_many(8)
		ok(ws, 'server websocket should be returned before receive test')
		eq(svc:stats().active_websockets, 1)

		local waiter = ok(scope:child())
		ok(waiter:spawn(function () fibers.perform(ws:receive_op()) end))
		local runner = ok(scope:child())
		ok(runner:spawn(function () raw_ctx:_drain_one_for_test() end))
		yield_until(function () return receive_active end, 'public websocket receive should be active')

		waiter:cancel('caller_cancelled')
		fibers.perform(waiter:join_op())
		yield_until(function () return svc:stats().active_websockets == 0 end,
			'websocket termination should deregister the service record')
		ok(ws:is_closed(), 'cancelling a public websocket receive should terminate the websocket')
		eq(ws:why(), 'aborted')
		runner:cancel('done')
		fibers.perform(runner:join_op())
		svc:terminate('done')
	end)
end

function M.test_public_open_exchange_handle_read_cancellation_keeps_service_backend_usable()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local first_stream
	local first_read_active = false
	local request_mod = {
		new_from_uri = function (uri)
			return {
				uri = uri,
				headers = {
					upsert = function () end,
					append = function () end,
				},
				go = function (self)
					local headers = fake_headers(200)
					if tostring(self.uri):match('slow') then
						first_stream = {
							terminated = false,
							get_next_chunk = function (stream)
								first_read_active = true
								while not stream.terminated do runtime.yield() end
								return nil, 'closed'
							end,
							terminate = function (stream) stream.terminated = true; return true end,
						}
						return headers, first_stream
					end
					local chunks = { 'ok' }
					local i = 0
					return headers, {
						get_next_chunk = function () i = i + 1; return chunks[i] end,
						shutdown = function () return true end,
					}
				end,
				shutdown = function () return true end,
			}
		end,
	}

	fibers.run(function (scope)
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		local svc = ok(http_service.open_handle(root, {
			driver = drv,
			id = 'main',
			request_module = request_mod,
		}))
		local user = b:connect({ origin_base = { kind = 'local' } })
		local ref = sdk_mod.new_ref(user, 'main')

		local rep = ok(fibers.perform(ref:open_exchange_op({ uri = 'http://example.test/slow', method = 'GET' })))
		local ex = ok(rep.exchange)
		yield_many(8)
		eq(svc:stats().active_exchanges, 1)

		local waiter = ok(scope:child())
		ok(waiter:spawn(function () fibers.perform(ex:read_chunk_op(1024)) end))
		yield_until(function () return first_read_active end, 'slow exchange read should be active')
		-- The driver pump runs the active read job.  Once the caller loses interest,
		-- the public exchange handle should terminate that stream, not the backend.
		waiter:cancel('caller_cancelled')
		fibers.perform(waiter:join_op())
		yield_until(function () return svc:stats().active_exchanges == 0 end,
			'exchange termination should deregister the service record')

		ok(first_stream.terminated, 'public exchange read cancellation should terminate the exchange stream')
		ok(ex:is_closed(), 'public exchange handle should be closed after active read abort')
		ok(not drv:is_closed(), 'the exchange is the narrow owner; the HTTP backend should stay usable')

		local second = ok(fibers.perform(ref:exchange_op({ uri = 'http://example.test/fast', method = 'GET' })))
		eq(second.result.status, '200')
		eq(svc:stats().completed_exchanges, 1, 'a subsequent public exchange should complete after active read cancellation')
		svc:terminate('done')
	end)
end

function M.test_retained_http_config_updates_policy_generation_and_policy()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		root:retain({ 'cfg', 'http' }, {
			rev = 7,
			data = {
				schema = require('services.http.config').SCHEMA,
				policy = { allow_loopback = false, allowed_schemes = { https = true } },
			},
		})
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		yield_until(function () return svc:stats().policy_generation == 7 end, 'retained cfg/http was not applied')
		eq(svc._opts.policy.allow_loopback, false)
		eq(svc._opts.policy.allowed_schemes.https, true)
		eq(svc._opts.policy.allowed_schemes.http, nil)
		svc:terminate('done')
	end)
end

function M.test_invalid_retained_http_config_marks_service_degraded_without_replacing_policy()
	fibers.run(function ()
		local b = bus.new()
		local root = b:connect({ origin_base = { kind = 'local' } })
		root:retain({ 'cfg', 'http' }, { rev = 3, data = { schema = 'wrong' } })
		local svc = ok(http_service.open_handle(root, { driver = fake_driver(), id = 'main' }))
		yield_until(function () return svc:stats().last_error ~= nil end, 'invalid cfg/http was not reported')
		ok(tostring(svc:stats().last_error):find('schema', 1, true))
		eq(svc:stats().policy_generation, 1, 'invalid config must not advance policy generation')
		svc:terminate('done')
	end)
end

return M
