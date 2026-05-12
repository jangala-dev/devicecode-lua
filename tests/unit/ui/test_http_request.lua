-- tests/unit/ui/test_http_request.lua

local run_fibers = require 'tests.support.run_fibers'
local fibers = require 'fibers'
local channel = require 'fibers.channel'
local request = require 'services.ui.http.request'
local routes = require 'services.ui.http.routes'
local read_model = require 'services.ui.read_model'
local auth = require 'services.ui.auth'
local sessions = require 'services.ui.sessions'
local cjson = require 'cjson.safe'
local authz = require 'devicecode.authz'

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

local function fake_json_ctx(method, path, body)
	local ctx = fake_ctx(method, path)
	ctx.read_body_as_string_op = function ()
		return fibers.always(function ()
			return body or ''
		end):wrap(function (th)
			return th()
		end)
	end
	return ctx
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

function tests.test_fabric_link_endpoint_returns_session_status_view()
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
				peer_sid = 'peer-sid-1',
			},
		})
		local ctx = fake_ctx('GET', '/api/fabric/link/mcu0')
		local result = request.run(scope, ctx, { model = model })
		assert_eq(result.status, 'ok')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		local reply = assert(cjson.decode(ctx.replies[1].body))
		assert_eq(reply.session.link_id, 'mcu0')
		assert_eq(reply.session.status.ready, true)
		assert_eq(reply.session.status.state, 'ready')
		assert_eq(reply.session.status.peer_node, 'mcu-1')
	end)
end

function tests.test_update_job_endpoint_returns_lifecycle_view()
	run_fibers.run(function (scope)
		local model = read_model.new()
		model:set({ 'state', 'workflow', 'update-job', 'job-1' }, {
			job_id = 'job-1',
			component = 'mcu',
			state = 'awaiting_commit',
			stage = 'staged',
			next_step = 'commit',
		})
		local ctx = fake_ctx('GET', '/api/update/jobs/job-1')
		local result = request.run(scope, ctx, { model = model })
		assert_eq(result.status, 'ok')
		local reply = assert(cjson.decode(ctx.replies[1].body))
		assert_eq(reply.ok, true)
		assert_eq(reply.job.job_id, 'job-1')
		assert_eq(reply.job.lifecycle.state, 'awaiting_commit')
		assert_eq(reply.job.lifecycle.stage, 'staged')
		assert_eq(reply.job.lifecycle.next_step, 'commit')
	end)
end

function tests.test_routes_decode_harness_update_endpoints()
	local upload = routes.decode({ method = 'POST', path = '/api/update/uploads' })
	assert_eq(upload.kind, 'upload')
	local action = routes.decode({ method = 'POST', path = '/api/update/jobs/job-1/do' })
	assert_eq(action.kind, 'update_job_action')
	assert_eq(action.job_id, 'job-1')
end

function tests.test_update_job_action_posts_commit_to_update_manager()
	run_fibers.run(function (scope)
		local captured = {}
		local conn = {
			call_op = function(_, topic, payload)
				captured.topic = topic
				captured.payload = payload
				return fibers.always(function ()
					return { ok = true, accepted = true }
				end):wrap(function (th)
					return th()
				end)
			end,
			disconnect = function () return true end,
		}
		local bus = {
			connect = function(_, opts)
				captured.principal = opts and opts.principal
				return conn
			end,
		}
		local store = sessions.new()
		local sess = store:create(authz.user_principal('admin', { roles = { 'admin' } }))
		local ctx = fake_json_ctx('POST', '/api/update/jobs/job-1/do', cjson.encode({ op = 'commit' }))
		ctx.session_id = sess.id
		local result = request.run(scope, ctx, {
			model = read_model.new(),
			sessions = store,
			bus = bus,
		})
		assert_eq(result.status, 'ok')
		assert_eq(captured.principal.id, 'admin')
		assert_eq(captured.principal.roles[1], 'admin')
		assert_eq(captured.topic[1], 'cap')
		assert_eq(captured.topic[2], 'update-manager')
		assert_eq(captured.topic[5], 'commit-job')
		assert_eq(captured.payload.job_id, 'job-1')
		assert_eq(captured.payload.op, 'commit')
	end)
end

function tests.test_update_upload_uses_authenticated_principal_for_update_bus()
	run_fibers.run(function (scope)
		local captured = { calls = {} }
		local sink = {
			append_op = function () return fibers.always(true, nil) end,
			commit_op = function () return fibers.always({ ref = 'artifact-1' }, nil) end,
			terminate = function () return true, nil end,
		}
		local conn = {
			call_op = function(_, topic, payload)
				local method = topic[#topic]
				captured.calls[#captured.calls + 1] = method
				if method == 'create_sink' then
					captured.sink = sink
					return fibers.always(function ()
						return { ok = true, reason = sink }
					end):wrap(function (th)
						return th()
					end)
				elseif method == 'create' then
					captured.ingest_sink = payload and payload.sink
					return fibers.always(function ()
						return { ingest = { ingest_id = 'ingest-1' } }
					end):wrap(function (th)
						return th()
					end)
				elseif method == 'append' then
					captured.chunk = payload and payload.chunk
					return fibers.always(function ()
						return { ok = true }
					end):wrap(function (th)
						return th()
					end)
				elseif method == 'commit' then
					return fibers.always(function ()
						return { artifact = { artifact_id = 'artifact-1' } }
					end):wrap(function (th)
						return th()
					end)
				end
				return fibers.always(function ()
					return nil, 'unexpected ingest method'
				end):wrap(function (th)
					return th()
				end)
			end,
			disconnect = function () return true end,
		}
		local bus = {
			connect = function(_, opts)
				captured.principal = opts and opts.principal
				return conn
			end,
		}
		local store = sessions.new()
		local sess = store:create(authz.user_principal('admin', { roles = { 'admin' } }))
		local ctx = fake_ctx('POST', '/api/update/uploads')
		ctx.headers = { ['x-session-id'] = sess.id }
		local chunks = { 'firmware-bytes' }
		ctx.read_chunk_op = function ()
			return fibers.always(function ()
				return table.remove(chunks, 1)
			end):wrap(function (th)
				return th()
			end)
		end

		local result = request.run(scope, ctx, {
			sessions = store,
			update = { bus = bus },
		})
		assert_eq(result.status, 'ok')
		assert_eq(result.artifact_id, 'artifact-1')
		assert_eq(captured.principal.id, 'admin')
		assert_eq(captured.principal.roles[1], 'admin')
		assert_eq(captured.ingest_sink, sink)
		assert_eq(captured.chunk, 'firmware-bytes')
		assert_eq(ctx.replies[1].status, 200)
	end)
	end

function tests.test_update_upload_emits_stage_logs()
	run_fibers.run(function (scope)
		local seen = {}
		local sink = {
			append_op = function () return fibers.always(true, nil) end,
			commit_op = function () return fibers.always({ ref = 'artifact-logs' }, nil) end,
			terminate = function () return true, nil end,
		}
		local log_conn = {
			publish = function(_, topic, payload)
				if topic[1] == 'obs' and topic[2] == 'log' and payload and payload.what then
					seen[#seen + 1] = payload.what
				end
				return true
			end,
		}
		local conn = {
			call_op = function(_, topic)
				local method = topic[#topic]
				if method == 'create_sink' then
					return fibers.always({ ok = true, reason = sink })
				elseif method == 'create' then
					return fibers.always({ ingest = { ingest_id = 'ingest-logs' } })
				elseif method == 'append' then
					return fibers.always({ ok = true })
				elseif method == 'commit' then
					return fibers.always({ artifact = { artifact_id = 'artifact-logs' } })
				end
				return fibers.always(nil, 'unexpected ingest method')
			end,
			disconnect = function () return true end,
		}
		local bus = { connect = function () return conn end }
		local store = sessions.new()
		local sess = store:create(authz.user_principal('admin', { roles = { 'admin' } }))
		local ctx = fake_ctx('POST', '/api/update/uploads')
		ctx.headers = { ['x-session-id'] = sess.id, ['x-artifact-image-id'] = 'mcu-dev-13.0' }
		local chunks = { 'firmware-bytes' }
		ctx.read_chunk_op = function ()
			return fibers.always(function ()
				return table.remove(chunks, 1)
			end):wrap(function (th)
				return th()
			end)
		end

		local result = request.run(scope, ctx, {
			conn = log_conn,
			sessions = store,
			update = { bus = bus },
		})
		assert_eq(result.status, 'ok')
		assert_eq(table.concat(seen, ','), table.concat({
			'upload_begin',
			'upload_ingest_begin',
			'upload_connect_begin',
			'upload_connect_ok',
			'upload_sink_create_begin',
			'upload_sink_create_ok',
			'upload_ingest_open_begin',
			'upload_ingest_open_ok',
			'upload_body_read_begin',
			'upload_body_read_end',
			'upload_ingest_commit_begin',
			'upload_ingest_commit_ok',
			'upload_ok',
		}, ','))
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

function tests.test_unknown_route_replies_not_found_once()
	run_fibers.run(function (scope)
		local ctx = fake_ctx('GET', '/api/nope')
		local result = request.run(scope, ctx, { model = read_model.new() })
		assert_eq(result.status, 'not_found')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 404)
	end)
end

function tests.test_login_decodes_http_json_body_and_returns_session_id()
	run_fibers.run(function (scope)
		local ctx = fake_json_ctx('POST', '/api/login', cjson.encode({
			username = 'admin',
			password = 'e2e',
		}))
		local result = request.run(scope, ctx, {
			auth = auth.new({ users = { admin = 'e2e' } }),
			sessions = sessions.new(),
		})
		assert_eq(result.status, 'ok')
		assert_not_nil(result.session_id)
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		local reply = assert(cjson.decode(ctx.replies[1].body))
		assert_eq(reply.session_id, result.session_id)
		assert_not_nil(reply.session)
	end)
end

function tests.test_login_rejects_invalid_json_body_as_bad_request()
	run_fibers.run(function (scope)
		local ctx = fake_json_ctx('POST', '/api/login', '{')
		local result = request.run(scope, ctx, {
			auth = auth.new({ users = { admin = 'e2e' } }),
			sessions = sessions.new(),
		})
		assert_eq(result.status, 'bad_request')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 400)
	end)
end

return tests
