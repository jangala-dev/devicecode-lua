-- tests/unit/ui/test_http_request.lua

local run_fibers = require 'tests.support.run_fibers'
local fibers = require 'fibers'
local channel = require 'fibers.channel'
local busmod = require 'bus'
local request = require 'services.ui.http.request'
local read_model = require 'services.ui.read_model'
local sse = require 'services.ui.http.sse'

local ok_cjson, cjson = pcall(require, 'cjson.safe')
if not ok_cjson then cjson = require 'cjson' end

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end
end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end
local function assert_true(v, msg)
	if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end
end

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

function tests.test_sse_route_opens_without_replaying_large_bootstrap_state()
	run_fibers.run(function (scope)
		local model = read_model.new()
		for i = 1, 40 do
			model:set({ 'state', 'bulk', tostring(i) }, { n = i })
		end
		local watch_owner = read_model.new_watches(model)
		local headers_ch = channel.new(1)
		local chunk_ch = channel.new(1)
		local ctx = fake_ctx('GET', '/events')

		ctx.write_headers_op = function(self, status, headers, opts)
			return fibers.always(function ()
				self._current = { status = status, body = '', headers = headers, end_stream = opts and opts.end_stream }
				headers_ch:put({ status = status, headers = headers })
				return true, nil
			end):wrap(function (th)
				return th()
			end)
		end
		ctx.write_chunk_op = function(self, chunk, opts)
			return fibers.always(function ()
				assert(self._current, 'no response headers')
				self._current.body = self._current.body .. tostring(chunk or '')
				chunk_ch:put(tostring(chunk or ''))
				if opts and opts.end_stream then
					self.replies[#self.replies + 1] = self._current
					self._current = nil
				end
				return true, nil
			end):wrap(function (th)
				return th()
			end)
		end

		local ok_spawn, spawn_err = scope:spawn(function ()
			request.run(scope, ctx, {
				watch_owner = watch_owner,
				encode_json = function (v) return assert(cjson.encode(v)) end,
			})
		end)
		assert_true(ok_spawn, spawn_err)

		local headers = headers_ch:get()
		assert_not_nil(headers)
		assert_eq(headers.status, 200)
		assert_eq(headers.headers['content-type'], 'text/event-stream')
		assert_eq(watch_owner:watch_count(), #sse.default_patterns())

		watch_owner:set({ 'state', 'system', 'stats' }, {
			cpu = { utilisation = 12.5 },
		})
		local metric_chunk = chunk_ch:get()
		assert_not_nil(metric_chunk)
		assert_true(metric_chunk:find('event: set', 1, true) ~= nil, metric_chunk)
		assert_true(metric_chunk:find('state/system/stats', 1, true) ~= nil, metric_chunk)
		assert_true(metric_chunk:find('12.5', 1, true) ~= nil, metric_chunk)

		watch_owner:set({ 'raw', 'secret' }, { leaked = true })
		watch_owner:set({ 'state', 'device', 'component', 'switch-main' }, {
			available = true,
			observed = { wired = { raw = { leaked = true } } },
			raw = { leaked = true },
		})
		local chunk = chunk_ch:get()
		assert_not_nil(chunk)
		assert_true(chunk:find('event: set', 1, true) ~= nil, chunk)
		assert_true(chunk:find('state/device/component/switch%-main') ~= nil, chunk)
		assert_true(chunk:find('raw/secret', 1, true) == nil, chunk)
		assert_true(chunk:find('leaked', 1, true) == nil, chunk)
		assert_true(chunk:find('"observed"', 1, true) == nil, chunk)
	end)
end

function tests.test_sse_route_opens_only_local_ui_prefix_watches()
	run_fibers.run(function (scope)
		local headers_ch = channel.new(1)
		local opened = {}
		local ctx = fake_ctx('GET', '/events')

		ctx.write_headers_op = function(self, status, headers, opts)
			return fibers.always(function ()
				self._current = { status = status, body = '', headers = headers, end_stream = opts and opts.end_stream }
				headers_ch:put({ status = status, headers = headers })
				return true, nil
			end):wrap(function (th)
				return th()
			end)
		end

		local watch_owner = {
			watch_open = function(_, pattern, opts)
				local watch = {
					pattern = pattern,
					opts = opts,
					terminated = nil,
					recv_op = function ()
						return fibers.never()
					end,
					terminate = function(self, reason)
						self.terminated = reason or true
						return true
					end,
				}
				opened[#opened + 1] = {
					pattern = pattern,
					opts = opts,
				}
				return watch, nil
			end,
		}

		local ok_spawn, spawn_err = scope:spawn(function ()
			request.run(scope, ctx, {
				watch_owner = watch_owner,
				encode_json = function (v) return assert(cjson.encode(v)) end,
			})
		end)
		assert_true(ok_spawn, spawn_err)

		local headers = headers_ch:get()
		assert_not_nil(headers)
		assert_eq(headers.status, 200)
		assert_eq(headers.headers['content-type'], 'text/event-stream')

		local defaults = sse.default_patterns()
		assert_eq(#opened, #defaults)
		local seen = {}
		for _, rec in ipairs(opened) do
			local key = table.concat(rec.pattern, '/')
			if key == '#' then fail('SSE opened root # watch') end
			seen[key] = true
			assert_eq(rec.opts.replay, false)
			assert_eq(rec.opts.queue_len, 32)
			assert_eq(rec.opts.full, 'drop_oldest')
		end
		assert_true(seen['state/device/#'] == true, 'state/device watch missing')
		assert_true(seen['state/net/#'] == true, 'state/net watch missing')
		assert_true(seen['obs/v1/system/metric/#'] == nil, 'system metric watch should not be opened')
			assert_true(seen['state/system/#'] == true, 'state/system watch missing')
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


function tests.test_update_commit_route_calls_update_manager_without_session()
	run_fibers.run(function (scope)
		local bus = busmod.new()
		local admin = bus:connect({ origin_base = { service = 'ui-update-commit-test' } })
		local caller = bus:connect({ origin_base = { service = 'ui' } })
		local received
		local ep = assert(admin:bind({ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }, { queue_len = 1 }))
		scope:finally(function () ep:close(); caller:disconnect(); admin:disconnect() end)

		fibers.spawn(function ()
			local req = ep:recv()
			received = req.payload
			req:reply({ ok = true })
		end)

		local ctx = fake_ctx('POST', '/api/update/commit')
		ctx.headers = { ['content-type'] = 'application/json' }
		ctx.read_body_as_string_op = function ()
			return fibers.always('{"job_id":"job-1"}', nil)
		end

		local result = request.run(scope, ctx, {
			bus = bus,
			update = {
				conn = caller,
				commit_require_auth = false,
				connect = function () error('public update commit should borrow supplied service conn') end,
			},
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})

		assert_eq(result.status, 'ok')
		assert_not_nil(received)
		assert_eq(received.job_id, 'job-1')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		local decoded = assert(cjson.decode(ctx.replies[1].body), ctx.replies[1].body)
		assert_eq(decoded.value.ok, true)
	end)
end

function tests.test_update_commit_route_obeys_auth_policy_when_enabled()
	run_fibers.run(function (scope)
		local bus = busmod.new()
		local ctx = fake_ctx('POST', '/api/update/commit')
		ctx.headers = { ['content-type'] = 'application/json' }
		ctx.read_body_as_string_op = function () return fibers.always('{"job_id":"job-1"}', nil) end

		local result = request.run(scope, ctx, {
			bus = bus,
			update = { bus = bus, commit_require_auth = true },
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})

		assert_eq(result.status, 'unauthenticated')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 401)
	end)
end

function tests.test_http_command_route_rejects_non_json_body()
	run_fibers.run(function (scope)
		local bus = busmod.new()
		local ctx = fake_ctx('POST', '/api/call/cap/test/main/rpc/echo')
		ctx.headers = { ['content-type'] = 'text/plain', ['x-session-id'] = 'sid-1' }
		ctx.read_body_as_string_op = function () return fibers.always('not json', nil) end
		local sessions = { get = function () return { id = 'sid-1', principal = 'tester' } end }
		local result = request.run(scope, ctx, {
			bus = bus,
			sessions = sessions,
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})
		assert_eq(result.status, 'bad_request')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 415)
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
