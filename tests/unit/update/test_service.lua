-- tests/unit/update/test_service.lua

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local busmod = require 'bus'

local update = require 'services.update'
local service = require 'services.update.service'
local topics = require 'services.update.topics'
local probe = require 'tests.support.bus_probe'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end

local function run_service_once(params)
	return fibers.run_scope(function (scope)
		return service.run(scope, params)
	end)
end

function tests.test_public_update_module_exports_start_and_run()
	assert_eq(type(update.start), 'function')
	assert_eq(type(update.run), 'function')
	assert_not_nil(update.config)
	assert_not_nil(update.service)
end

function tests.test_service_run_completes_with_injected_generation_runner()
	fibers.run(function ()
		local st, rep, result = run_service_once {
			publish = false,
			service_id = 'update',
			job_store_kind = 'memory',
			watch_config = false,
			generation_runner = function (_, params)
				return {
					role = 'fake_generation',
					generation = params.generation,
				}
			end,
		}

		assert_eq(st, 'ok')
		assert_eq(#rep.extra_errors, 0)
		assert_eq(result.role, 'update_service')
		assert_eq(result.snapshot.state, 'stopped')

	end)
end

function tests.test_manager_status_request_replies_immediately()
	fibers.run(function (root_scope)
		local bus = busmod.new()
		local svc_conn = bus:connect()
		local caller = bus:connect()

		local child, cerr = root_scope:child()
		assert_not_nil(child, cerr)
		local ok, err = child:spawn(function (scope)
			service.run(scope, {
				conn = svc_conn,
				service_id = 'update',
				job_store_kind = 'memory',
				watch_config = false,
			})
		end)
		assert_true(ok, err)

		-- Let the manager endpoint bind.
		fibers.perform(sleep.sleep_op(0.01))

		local reply, call_err = caller:call(topics.update_manager_rpc('status'), {}, { timeout = 0.2 })
		assert_not_nil(reply, call_err)
		assert_eq(reply.ok, true)
		assert_eq(reply.snapshot.service, 'update')

		child:cancel('test complete')
	end)
end

function tests.test_config_change_replaces_generation()
	fibers.run(function (root_scope)
		local bus = busmod.new()
		local svc_conn = bus:connect()
		local cfg_conn = bus:connect()
		local caller = bus:connect()

		local child = assert(root_scope:child())
		local ok, err = child:spawn(function (scope)
			service.run(scope, {
				conn = svc_conn,
				service_id = 'update',
				job_store_kind = 'memory',
			})
		end)
		assert_true(ok, err)

		fibers.perform(sleep.sleep_op(0.02))

		cfg_conn:retain(topics.config(), {
			rev = 2,
			data = {
				schema = 'devicecode.update/1',
				namespace = 'new-ns',
				components = {
					{ component = 'cm5' },
				},
			},
		})

		local reply
		local ok_wait = probe.wait_until(function ()
			reply = caller:call(topics.update_manager_rpc('status'), {}, { timeout = 0.03 })
			return reply and reply.snapshot and reply.snapshot.config and reply.snapshot.config.namespace == 'new-ns'
		end, { timeout = 0.4, interval = 0.01 })

		assert_true(ok_wait, 'expected config replacement to be visible')
		assert_eq(reply.snapshot.config.component_count, 1)

		child:cancel('test complete')
	end)
end


function tests.test_service_shell_routes_manager_request_to_generation_private_queue()
	fibers.run(function (root_scope)
		local bus = busmod.new()
		local svc_conn = bus:connect()
		local caller = bus:connect()
		local child = assert(root_scope:child())
		local got_private_request = false

		local ok, err = child:spawn(function (scope)
			service.run(scope, {
				conn = svc_conn,
				service_id = 'update',
				job_store_kind = 'memory',
				watch_config = false,
				publish = false,
				generation_runner = function (_, params)
					local req = fibers.perform(params.manager_rx:recv_op())
					got_private_request = req ~= nil
					if req then req:reply({ ok = true, generation = params.generation }) end
					return { role = 'fake_generation', generation = params.generation }
				end,
			})
		end)
		assert_true(ok, err)

		fibers.perform(sleep.sleep_op(0.02))
		local reply, call_err = caller:call(topics.update_manager_rpc('status'), {}, { timeout = 0.5 })
		assert_not_nil(reply, call_err)
		assert_eq(reply.ok, true)
		assert_true(got_private_request, 'expected request to arrive through generation private route')

		child:cancel('test complete')
	end)
end

function tests.test_publisher_failure_is_supervised_component_failure()
	fibers.run(function ()
		local bus = busmod.new({
			authoriser = function (ctx)
				if ctx.action == 'retain' then return false, 'retain_denied' end
				return true, nil
			end,
		})
		local svc_conn = bus:connect()

		local st, _, primary = fibers.run_scope(function (scope)
			return service.run(scope, {
				conn = svc_conn,
				service_id = 'update',
				job_store_kind = 'memory',
				watch_config = false,
				generation_runner = function ()
					fibers.perform(sleep.sleep_op(10))
					return { role = 'never' }
				end,
			})
		end)

		assert_eq(st, 'failed')
		assert_true(tostring(primary):find('publisher') ~= nil or tostring(primary):find('retain_denied') ~= nil)
	end)
end

function tests.test_service_uses_shared_config_watch_helper()
	local source = assert(io.open('../src/services/update/service.lua', 'r')):read('*a')
	assert_true(source:find("devicecode.support.config_watch", 1, true) ~= nil, 'update service should require shared config_watch helper')
	assert_true(source:find('config_watch.open', 1, true) ~= nil, 'update service should open cfg/update through shared config_watch')
	assert_true(source:find('watch_retained(conn, topics.config()', 1, true) == nil, 'update service should not own a bespoke retained config watcher')
end

function tests.test_service_start_path_allows_injected_config_watch_for_harnesses()
	fibers.run(function ()
		local rx = {
			recv_op = function () return sleep.sleep_op(10) end,
		}
		local st, _, primary = fibers.run_scope(function (scope)
			scope:spawn(function ()
				service.run(scope, {
					publish = false,
					service_id = 'update',
					job_store_kind = 'memory',
					config_watch = rx,
					generation_runner = function ()
						fibers.perform(sleep.sleep_op(10))
						return { role = 'never' }
					end,
				})
			end)
			fibers.perform(sleep.sleep_op(0.01))
			scope:cancel('test complete')
		end)
		assert_eq(st, 'cancelled')
		assert_eq(primary, 'test complete')
	end)
end

return tests
