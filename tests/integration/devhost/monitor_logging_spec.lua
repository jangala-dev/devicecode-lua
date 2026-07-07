local busmod     = require 'bus'
local fibers     = require 'fibers'
local cjson_ok, cjson = pcall(require, 'cjson.safe')
if not cjson_ok then cjson = require 'cjson' end

local run_fibers = require 'tests.support.run_fibers'
local probe      = require 'tests.support.bus_probe'
local monitor    = require 'services.monitor'
local request    = require 'services.ui.http.request'

local T = {}

local function assert_eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function assert_true(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

local function monitor_rpc(method) return { 'cap', 'monitor', 'main', 'rpc', method } end
local function log_topic(service) return { 'obs', 'v1', service, 'event', 'log' } end

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
			end):wrap(function (th) return th() end)
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
			end):wrap(function (th) return th() end)
		end,
		terminate = function(self, reason) self.abandoned = reason; return true end,
	}
end

local function publish_log(conn, service, level, what, summary)
	conn:publish(log_topic(service), {
		service = service,
		level = level or 'info',
		what = what,
		summary = summary or what,
	})
end

function T.monitor_public_capability_feeds_ui_initial_logs()
	run_fibers.run(function (scope)
		local b = busmod.new()
		local monitor_conn = b:connect({ origin_base = { service = 'monitor' } })
		local app_conn = b:connect({ origin_base = { service = 'app' } })
		local ui_conn = b:connect({ origin_base = { service = 'ui' } })
		local ok, err = scope:spawn(function () monitor.start(monitor_conn, { env = 'test' }) end)
		assert_true(ok, tostring(err))
		probe.wait_retained_payload(ui_conn, { 'cap', 'monitor', 'main' }, { timeout = 0.5 })

		publish_log(app_conn, 'net', 'info', 'speedtest_completed', 'speedtest wan on wan/vl-wan: 100 Mbps')
		probe.wait_until(function ()
			local rep = ui_conn:call(monitor_rpc('query-logs'), { service = 'net', limit = 1 }, { timeout = 0.05 })
			return rep and rep.count == 1
		end, { timeout = 0.8, interval = 0.01 })

		local ctx = fake_ctx('GET', '/api/logs')
		local result = request.run(scope, ctx, {
			conn = ui_conn,
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})
		assert_eq(result.status, 'ok')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		local decoded = assert_true(cjson.decode(ctx.replies[1].body), ctx.replies[1].body)
		assert_true(decoded.records and #decoded.records >= 1, 'expected log records in UI response')
		local found = false
		for _, rec in ipairs(decoded.records) do
			if rec.service == 'net' and rec.what == 'speedtest_completed' then found = true end
		end
		assert_true(found, 'UI logs response should include monitor query result')
	end)
end

function T.ui_logs_endpoint_can_request_boot_buffer()
	run_fibers.run(function (scope)
		local b = busmod.new()
		local admin = b:connect({ origin_base = { service = 'monitor-test-admin' } })
		admin:retain({ 'cfg', 'monitor' }, {
			data = { storage = { boot_records = 10, ring_records = 2, boot_seconds = 0 } },
			rev = 1,
		})
		local monitor_conn = b:connect({ origin_base = { service = 'monitor' } })
		local app_conn = b:connect({ origin_base = { service = 'app' } })
		local ui_conn = b:connect({ origin_base = { service = 'ui' } })
		local ok, err = scope:spawn(function () monitor.start(monitor_conn, { env = 'test' }) end)
		assert_true(ok, tostring(err))
		probe.wait_retained_payload(ui_conn, { 'cap', 'monitor', 'main' }, { timeout = 0.5 })

		for i = 1, 5 do publish_log(app_conn, 'alpha', 'info', 'record_' .. i, 'record ' .. i) end
		probe.wait_until(function ()
			local rep = ui_conn:call(monitor_rpc('query-logs'), { service = 'alpha', limit = 10 }, { timeout = 0.05 })
			return rep and rep.count == 2 and rep.records[1].what == 'record_4'
		end, { timeout = 0.8, interval = 0.01 })

		local ring_ctx = fake_ctx('GET', '/api/logs')
		local ring_result = request.run(scope, ring_ctx, {
			conn = ui_conn,
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})
		assert_eq(ring_result.status, 'ok')
		local ring = assert_true(cjson.decode(ring_ctx.replies[1].body), ring_ctx.replies[1].body)

		local boot_ctx = fake_ctx('GET', '/api/logs?boot=true')
		local boot_result = request.run(scope, boot_ctx, {
			conn = ui_conn,
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})
		assert_eq(boot_result.status, 'ok')
		local boot = assert_true(cjson.decode(boot_ctx.replies[1].body), boot_ctx.replies[1].body)

		local ring_found_first = false
		for _, rec in ipairs(ring.records or {}) do
			if rec.service == 'alpha' and rec.what == 'record_1' then ring_found_first = true end
		end
		assert_true(not ring_found_first, 'plain UI logs response should use the ring buffer')

		local boot_found_first = false
		for _, rec in ipairs(boot.records or {}) do
			if rec.service == 'alpha' and rec.what == 'record_1' then boot_found_first = true end
		end
		assert_true(boot_found_first, 'boot UI logs response should include startup records')
	end)
end

function T.monitor_profile_endpoint_changes_profile_through_ui_route()
	run_fibers.run(function (scope)
		local b = busmod.new()
		local monitor_conn = b:connect({ origin_base = { service = 'monitor' } })
		local ui_conn = b:connect({ origin_base = { service = 'ui' } })
		local ok, err = scope:spawn(function () monitor.start(monitor_conn, { env = 'test' }) end)
		assert_true(ok, tostring(err))
		probe.wait_retained_payload(ui_conn, { 'cap', 'monitor', 'main' }, { timeout = 0.5 })

		local ctx = fake_ctx('POST', '/api/monitor/profile')
		ctx.headers = { ['content-type'] = 'application/json', ['x-session-id'] = 'sid-1' }
		ctx.read_body_as_string_op = function () return fibers.always('{"profile":"debug"}', nil) end
		local sessions = {
			get = function (_, sid)
				if sid == 'sid-1' then
					return { id = sid, principal = { kind = 'user', id = 'tester' } }
				end
			end,
		}
		local result = request.run(scope, ctx, {
			conn = ui_conn,
			bus = b,
			sessions = sessions,
			-- Return the borrowed UI connection here to keep the test focused on
			-- route behaviour.  request.run passes deps.conn as the borrowed
			-- connection owner, so user_operation must not disconnect it.
			connect = function () return ui_conn end,
			encode_json = function (v) return assert(cjson.encode(v)) end,
		})
		assert_eq(result.status, 'ok')
		assert_eq(#ctx.replies, 1)
		assert_eq(ctx.replies[1].status, 200)
		probe.wait_until(function ()
			local rep = ui_conn:call(monitor_rpc('query-logs'), { limit = 0 }, { timeout = 0.05 })
			return rep and rep.summary and rep.summary.profile == 'debug'
		end, { timeout = 0.8, interval = 0.01 })
	end)
end

return T
