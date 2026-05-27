-- tests/unit/ui/test_http_request.lua

local run_fibers = require 'tests.support.run_fibers'
local fibers = require 'fibers'
local channel = require 'fibers.channel'
local busmod = require 'bus'
local request = require 'services.ui.http.request'
local read_model = require 'services.ui.read_model'

local ok_cjson, cjson = pcall(require, 'cjson.safe')
if not ok_cjson then cjson = require 'cjson' end

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function fake_ctx(method, path)
	return {
		method = method,
		path = path,
		replies = {},
		_current = nil,
		write_headers_op = function(self, status, headers, opts)
			return fibers.always(function ()
				self._current = { status = status, body = '', headers = headers, end_stream = opts and opts.end_stream }
				if opts and opts.end_stream then
					self.replies[#self.replies + 1] = self._current
					self._current = nil
				end
				return true, nil
			end):wrap(function (th)
				return th()
			end)
		end,
		write_chunk_op = function(self, chunk, opts)
			return fibers.always(function ()
				assert(self._current, 'no response headers')
				self._current.body = self._current.body .. tostring(chunk or '')
				if opts and opts.end_stream then
					self.replies[#self.replies + 1] = self._current
					self._current = nil
				end
				return true, nil
			end):wrap(function (th)
				return th()
			end)
		end,
		terminate = function(self, reason)
			self.abandoned = reason
			return true
		end,
	}
end

local function body_from_chunks(chunks)
	return {
		_chunks = chunks,
		read_chunk_op = function (self)
			local chunk = table.remove(self._chunks, 1)
			return fibers.always(chunk, nil)
		end,
	}
end

function tests.test_http_read_request_uses_model_and_replies_once()
	run_fibers.run(function (scope)
		local model = read_model.new()
		model:set({ 'svc', 'ui', 'status' }, { state = 'running' })
		local ctx = fake_ctx('GET', '/api/state/svc/ui/status')
		local result = request.run(scope, ctx, { model = model })
		assert_eq(result.status, 'ok')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		assert_not_nil(ctx.replies[1].body)
	end)
end

function tests.test_fabric_link_route_returns_link_component_projection()
	run_fibers.run(function (scope)
		local model = read_model.new()
		model:set({ 'state', 'fabric', 'link', 'mcu0', 'component', 'session' }, {
			kind = 'fabric.component',
			link_id = 'mcu0',
			component = 'session',
			snapshot = {
				phase = 'established',
				established = true,
				peer_node = 'mcu-1',
			},
		})
		model:set({ 'state', 'fabric', 'link', 'mcu0', 'component', 'transfer_manager' }, {
			kind = 'fabric.component',
			link_id = 'mcu0',
			component = 'transfer_manager',
			state = 'ready',
			snapshot = {
				active = nil,
				last = nil,
			},
		})

		local ctx = fake_ctx('GET', '/api/fabric/link/mcu0')
		local result = request.run(scope, ctx, { model = model })
		assert_eq(result.status, 'ok')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		local decoded = assert(cjson.decode(ctx.replies[1].body))
		assert_eq(decoded.session.link_id, 'mcu0')
		assert_eq(decoded.session.status.ready, true)
		assert_eq(decoded.session.status.state, 'ready')
		assert_eq(decoded.session.status.phase, 'established')
		assert_eq(decoded.session.status.established, true)
		assert_eq(decoded.session.status.peer_node, 'mcu-1')
		assert_eq(decoded.transfer_manager.link_id, 'mcu0')
	end)
end

function tests.test_login_returns_nested_session_and_compat_session_id()
	run_fibers.run(function (scope)
		local ctx = fake_ctx('POST', '/api/login')
		ctx.body = { username = 'admin', password = 'e2e' }
		local sessions = {
			create = function (_, principal, opts)
				assert_eq(principal.id, 'admin')
				assert_not_nil(opts and opts.data)
				return { id = 'sid-1', principal = principal }
			end,
		}

		local result = request.run(scope, ctx, {
			auth = function (credentials)
				if credentials.username == 'admin' and credentials.password == 'e2e' then
					return { kind = 'user', id = 'admin' }, nil
				end
				return nil, 'unauthenticated'
			end,
			sessions = sessions,
		})

		assert_eq(result.status, 'ok')
		assert_eq(result.session_id, 'sid-1')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		local decoded = assert(cjson.decode(ctx.replies[1].body))
		assert_eq(decoded.session.id, 'sid-1')
		assert_eq(decoded.session_id, 'sid-1')
	end)
end


function tests.test_http_response_writer_may_yield_inside_request_scope_without_blocking_peers()
	run_fibers.run(function (scope)
		local model = read_model.new()
		model:set({ 'svc', 'ui', 'status' }, { state = 'running' })

		local started_ch = channel.new()
		local resume_ch = channel.new()
		local events = {}
		local ctx = fake_ctx('GET', '/api/state/svc/ui/status')
		ctx.write_headers_op = function(self, status, headers, opts)
			events[#events + 1] = 'reply-start'
			started_ch:put(true)
			return resume_ch:get_op():wrap(function (token)
				events[#events + 1] = 'reply-finish:' .. tostring(token)
				self._current = { status = status, body = '', headers = headers, end_stream = opts and opts.end_stream }
				return true, nil
			end)
		end

		fibers.spawn(function ()
			started_ch:get()
			events[#events + 1] = 'peer-fiber-ran'
			resume_ch:put('resumed')
		end)

		local result = request.run(scope, ctx, { model = model })
		assert_eq(result.status, 'ok')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		assert_eq(events[1], 'reply-start')
		assert_eq(events[2], 'peer-fiber-ran')
		assert_eq(events[3], 'reply-finish:resumed')
	end)
end


function tests.test_http_command_route_parses_real_json_body_and_calls_bus()
	run_fibers.run(function (scope)
		local bus = busmod.new()
		local admin = bus:connect({ origin_base = { service = 'ui-command-test' } })
		local received
		local ep = assert(admin:bind({ 'cap', 'test', 'main', 'rpc', 'echo' }, { queue_len = 1 }))
		scope:finally(function () ep:close(); admin:disconnect() end)

		fibers.spawn(function ()
			local req = ep:recv()
			received = req.payload
			req:reply({ echoed = req.payload })
		end)

		local ctx = fake_ctx('POST', '/api/call/cap/test/main/rpc/echo')
		ctx.headers = { ['content-type'] = 'application/json', ['x-session-id'] = 'sid-1' }
		ctx.read_body_as_string_op = function ()
			return fibers.always('{"job_id":"job-1","n":7}', nil)
		end

		local sessions = {
			get = function (_, sid)
				if sid == 'sid-1' then return { id = sid, principal = { kind = 'user', id = 'tester' } } end
				return nil
			end,
		}

		local result = request.run(scope, ctx, {
			bus = bus,
			sessions = sessions,
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})

		assert_eq(result.status, 'ok')
		assert_not_nil(received)
		assert_eq(received.job_id, 'job-1')
		assert_eq(received.n, 7)
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
	end)
end

function tests.test_http_command_route_rejects_non_json_body()
	run_fibers.run(function (scope)
		local bus = busmod.new()
		local ctx = fake_ctx('POST', '/api/call/cap/test/main/rpc/echo')
		ctx.headers = { ['content-type'] = 'text/plain', ['x-session-id'] = 'sid-1' }
		ctx.read_body_as_string_op = function () return fibers.always('not json', nil) end
		local sessions = { get = function () return { id = 'sid-1', principal = 'tester' } end }
		local result = request.run(scope, ctx, { bus = bus, sessions = sessions, encode_json = function (v) return assert(cjson.encode(v)) end })
		assert_eq(result.status, 'bad_request')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 415)
	end)
end

function tests.test_update_upload_route_uses_session_principal_for_bus_calls()
	run_fibers.run(function (scope)
		local captured_principal
		local calls = {}
		local conn = {
			call_op = function (_, topic, payload)
				calls[#calls + 1] = { topic = topic, payload = payload }
				local method = topic[#topic]
				if topic[2] == 'artifact-ingest' and method == 'create' then
					return fibers.always({ ingest = { ingest_id = payload.ingest_id or 'ing-upload' } }, nil)
				elseif topic[2] == 'artifact-ingest' and method == 'append' then
					return fibers.always({ ok = true }, nil)
				elseif topic[2] == 'artifact-ingest' and method == 'commit' then
					return fibers.always({ commit = { artifact = { artifact_ref = 'artifact-1' } } }, nil)
				elseif topic[2] == 'update-manager' and method == 'create-job' then
					assert_eq(payload.component, 'mcu')
					assert_eq(payload.metadata.image_id, 'mcu-dev-15.0')
					assert_eq(payload.metadata.expected_image_id, 'mcu-dev-15.0')
					assert_eq(payload.metadata.version, '15.0')
					assert_eq(payload.metadata.build, 'fw-update-e2e-15.0')
					assert_eq(payload.metadata.transfer_chunk_raw, 1024)
					return fibers.always({ job = { job_id = 'job-1', component = payload.component } }, nil)
				elseif topic[2] == 'update-manager' and method == 'start-job' then
					assert_eq(payload.job_id, 'job-1')
					return fibers.always({ ok = true }, nil)
				end
				return fibers.always(nil, 'unexpected method')
			end,
			disconnect = function () return true end,
		}
		local bus = {
			connect = function (_, opts)
				captured_principal = opts and opts.principal
				return conn, nil
			end,
		}
		local sessions = {
			get = function (_, sid)
				if sid == 'sid-1' then
					return { id = sid, principal = { kind = 'user', id = 'tester', roles = { 'admin' } } }
				end
				return nil
			end,
		}
		local ctx = fake_ctx('POST', '/api/update/upload')
		ctx.headers = {
			['x-session-id'] = 'sid-1',
			['x-artifact-component'] = 'mcu',
			['x-artifact-name'] = 'devicecode.dcmcu',
			['x-artifact-version'] = '15.0',
			['x-artifact-build'] = 'fw-update-e2e-15.0',
			['x-artifact-image-id'] = 'mcu-dev-15.0',
			['x-transfer-chunk-raw'] = '1024',
		}
		ctx.body_stream = body_from_chunks({ 'hello', 'world' })

		local result = request.run(scope, ctx, {
			sessions = sessions,
			update = {
				bus = bus,
				ingest_id = 'ing-upload',
			},
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})

		assert_eq(result.status, 'ok')
		assert_eq(captured_principal.id, 'tester')
		assert_eq(calls[1].topic[5], 'create')
		assert_eq(calls[2].topic[5], 'append')
		assert_eq(calls[3].topic[5], 'append')
		assert_eq(calls[4].topic[5], 'commit')
		assert_eq(calls[5].topic[5], 'create-job')
		assert_eq(calls[6].topic[5], 'start-job')
		assert_eq(result.job.job_id, 'job-1')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
	end)
end

function tests.test_update_upload_route_rejects_missing_session()
	run_fibers.run(function (scope)
		local ctx = fake_ctx('POST', '/api/update/upload')
		ctx.body_stream = body_from_chunks({ 'hello' })
		local result = request.run(scope, ctx, {
			sessions = { get = function () return nil end },
			update = {
				ingest = {
					open_ingest_op = function () error('upload must not start without a principal') end,
				},
			},
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})

		assert_eq(result.status, 'unauthenticated')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 401)
	end)
end

function tests.test_unknown_route_replies_not_found_once()
	run_fibers.run(function (scope)
		local ctx = fake_ctx('GET', '/api/nope')
		local result = request.run(scope, ctx, { model = read_model.new() })
		assert_eq(result.status, 'not_found')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 404)
	end)
end

return tests
