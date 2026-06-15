local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local busmod = require 'bus'

local runfibers = require 'tests.support.run_fibers'
local probe = require 'tests.support.bus_probe'
local mainmod = require 'devicecode.main'

local net_service = require 'services.net.service'
local net_config = require 'services.net.config'
local net_topics = require 'services.net.topics'
local update_service = require 'services.update.service'
local update_topics = require 'services.update.topics'
local ui_service = require 'services.ui.service'
local fabric = require 'services.fabric'
local fabric_topics = require 'services.fabric.topics'

local T = {}

local function assert_true(v, msg) if v ~= true then error(msg or ('expected true, got ' .. tostring(v)), 2) end end
local function assert_eq(a, b, msg) if a ~= b then error(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)), 2) end end
local function assert_not_nil(v, msg) if v == nil then error(msg or 'expected non-nil', 2) end return v end

local function net_cfg()
	return {
		schema = net_config.SCHEMA,
		version = 1,
		segments = {
			lan = { kind = 'lan', vlan = 10, addressing = { ipv4 = { mode = 'static', cidr = '172.28.10.1/24' } } },
		},
		interfaces = {
			lan_bridge = { kind = 'bridge', role = 'lan', segment = 'lan', members = { 'eth0' } },
		},
		wan = { members = {} },
	}
end

local function ui_cfg()
	return {
		schema = 'devicecode.config/ui/1',
		enabled = true,
		http = { enabled = true, cap_id = 'main', host = '127.0.0.1', port = 8080 },
		sessions = { prune_interval = false },
		updates = {
			upload = {
				enabled = true,
				max_bytes = 1024 * 1024,
				require_auth = false,
				component = 'mcu',
				create_job = true,
				start_job = true,
			},
			commit = { require_auth = false },
		},
	}
end

local function fabric_cfg()
	return {
		schema = fabric.config.SCHEMA,
		local_node = 'node-a',
		links = {
			{
				id = 'uart0',
				peer_id = 'node-b',
				transport = { source = 'uart', class = 'uart', id = 'main' },
				session = { hello_interval_s = 60, ping_interval_s = 60, liveness_timeout_s = 120 },
				bridge = {},
				transfer = {},
			},
		},
	}
end

local function make_blocking_line_session()
	return {
		read_line_op = function () return sleep.sleep_op(3600):wrap(function () return nil, 'closed' end) end,
		write_line_op = function () return fibers.always(true, nil) end,
		flush_op = function () return fibers.always(true, nil) end,
		terminate = function () return true, nil end,
	}
end

local function bind_http_listen(scope, bus, calls)
	local conn = bus:connect()
	local ep = assert(conn:bind({ 'cap', 'http', 'main', 'rpc', 'listen' }, { queue_len = 8 }))
	local ok, err = scope:spawn(function ()
		while true do
			local req = fibers.perform(ep:recv_op())
			if req == nil then return end
			calls[#calls + 1] = req.payload or {}
			req:reply({ listener = {
				accept_op = function () return sleep.sleep_op(3600):wrap(function () return nil, 'closed' end) end,
				terminate = function () return true, nil end,
			} })
		end
	end)
	assert_true(ok, err)
	conn:retain({ 'cap', 'http', 'main', 'status' }, { state = 'available', available = true })
	return conn
end

local function bind_raw_uart_open(scope, bus, opts)
	opts = opts or {}
	local conn = bus:connect()
	local ep = assert(conn:bind({ 'raw', 'host', 'uart', 'cap', 'uart', 'main', 'rpc', 'open' }, { queue_len = 8 }))
	local calls = opts.calls or {}
	local ok, err = scope:spawn(function ()
		while true do
			local req = fibers.perform(ep:recv_op())
			if req == nil then return end
			calls[#calls + 1] = req.payload or {}
			if opts.no_route_once then
				opts.no_route_once = false
				req:reply({ ok = false, reason = { err = 'no_route' } })
			else
				req:reply({ ok = true, reason = { session = make_blocking_line_session() } })
			end
		end
	end)
	assert_true(ok, err)
	conn:retain({ 'raw', 'host', 'uart', 'cap', 'uart', 'main', 'status' }, { state = 'available', available = true })
	return conn, calls
end

local function bind_network_config_apply(scope, bus, calls)
	local conn = bus:connect()
	local ep = assert(conn:bind({ 'cap', 'network-config', 'main', 'rpc', 'apply' }, { queue_len = 8 }))
	local ok, err = scope:spawn(function ()
		while true do
			local req = fibers.perform(ep:recv_op())
			if req == nil then return end
			local payload = req.payload or {}
			calls[#calls + 1] = payload
			req:reply({ ok = true, reason = { ok = true, applied = true, changed = true } })
		end
	end)
	assert_true(ok, err)
	conn:retain({ 'cap', 'network-config', 'main', 'status' }, { state = 'available', available = true })
	return conn
end

local function bind_fake_control_store(scope, bus, backing)
	backing = backing or {}
	local conn = bus:connect()
	for _, method in ipairs({ 'list', 'get', 'put', 'delete' }) do
		local ep = assert(conn:bind({ 'cap', 'control-store', 'update', 'rpc', method }, { queue_len = 8 }))
		local loop_method = method
		local ok, err = scope:spawn(function ()
			while true do
				local req = fibers.perform(ep:recv_op())
				if req == nil then return end
				local p = req.payload or {}
				if loop_method == 'list' then
					local keys, prefix = {}, p.prefix or ''
					for k in pairs(backing) do if k:sub(1, #prefix) == prefix then keys[#keys + 1] = k end end
					table.sort(keys)
					req:reply({ ok = true, reason = keys })
				elseif loop_method == 'get' then
					req:reply(backing[p.key] == nil and { ok = false, reason = 'not found' } or { ok = true, reason = backing[p.key] })
				elseif loop_method == 'put' then
					backing[p.key] = p.data; req:reply({ ok = true, reason = nil })
				else
					backing[p.key] = nil; req:reply({ ok = true, reason = nil })
				end
			end
		end)
		assert_true(ok, err)
	end
	conn:retain({ 'cap', 'control-store', 'update', 'status' }, { state = 'available', available = true })
	return conn
end


local function retained_payload(conn, topic)
	local view = conn:retained_view(topic)
	local msg = view:get(topic)
	view:close()
	return msg and msg.payload or nil
end

local function retain_artifact_store_available(bus)
	local conn = bus:connect()
	conn:retain({ 'cap', 'artifact-store', 'main', 'status' }, { state = 'available', available = true })
	return conn
end

function T.ui_waits_for_http_capability_before_starting_listener()
	runfibers.run(function (scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local reader = bus:connect()
		local calls = {}
		local child = assert(scope:child())
		assert_true(child:spawn(function () ui_service.start(conn, { config = ui_cfg() }) end))

		local waiting = probe.wait_retained_payload(reader, { 'svc', 'ui', 'status' }, { timeout = 0.8, view_topic = { 'svc', 'ui', 'status' } })
		assert_not_nil(waiting)
		assert_true(probe.wait_until(function ()
			local p = retained_payload(reader, { 'svc', 'ui', 'status' })
			return p and p.ready == false and p.listener_status == 'waiting_for_http'
		end, { timeout = 0.8, interval = 0.01 }), 'ui should wait for HTTP')

		local cap_scope = assert(scope:child())
		bind_http_listen(cap_scope, bus, calls)
		assert_true(probe.wait_until(function ()
			local view = reader:retained_view({ 'svc', 'ui', 'status' })
			local msg = view:get({ 'svc', 'ui', 'status' })
			view:close()
			local p = msg and msg.payload
			return p and p.ready == true and p.listener_status == 'running'
		end, { timeout = 0.8, interval = 0.01 }), 'ui should start listener after HTTP appears')
		assert_true(probe.wait_until(function ()
			return #calls == 1
		end, { timeout = 0.8, interval = 0.01 }), 'expected HTTP listen to be called after HTTP appears')

		child:cancel('test complete')
		cap_scope:cancel('test complete')
		fibers.perform(child:join_op())
		fibers.perform(cap_scope:join_op())
	end, { timeout = 2.0 })
end

function T.fabric_waits_for_raw_transport_and_recovers_after_route_missing()
	runfibers.run(function (scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local reader = bus:connect()
		local child = assert(scope:child())
		assert_true(child:spawn(function () fabric.start(conn, { config = fabric_cfg() }) end))

		assert_true(probe.wait_until(function ()
			local view = reader:retained_view(fabric_topics.svc_status())
			local msg = view:get(fabric_topics.svc_status())
			view:close()
			local p = msg and msg.payload
			return p and p.state == 'waiting_for_dependency'
				and p.dependencies and p.dependencies['transport:uart0']
				and p.dependencies['transport:uart0'].available == false
		end, { timeout = 0.8, interval = 0.01 }), 'fabric should wait for raw transport')

		local cap_scope = assert(scope:child())
		local calls = {}
		bind_raw_uart_open(cap_scope, bus, { calls = calls, no_route_once = true })

		assert_true(probe.wait_until(function ()
			local view = reader:retained_view(fabric_topics.svc_status())
			local msg = view:get(fabric_topics.svc_status())
			view:close()
			local p = msg and msg.payload
			local dep = p and p.dependencies and p.dependencies['transport:uart0']
			return p and p.state == 'waiting_for_dependency'
				and p.reason == 'transport_route_missing'
				and dep and dep.route_missing == true
		end, { timeout = 0.8, interval = 0.01 }), 'fabric should attribute no_route to transport dependency')

		-- Retaining a fresh available status clears route_missing and admits the pending generation again.
		bus:connect():retain({ 'raw', 'host', 'uart', 'cap', 'uart', 'main', 'status' }, { state = 'available', available = true })
		assert_true(probe.wait_until(function ()
			local view = reader:retained_view(fabric_topics.svc_status())
			local msg = view:get(fabric_topics.svc_status())
			view:close()
			local p = msg and msg.payload
			return p and p.state == 'running' and p.ready == true
		end, { timeout = 0.8, interval = 0.01 }), 'fabric should retry after transport route returns')
		assert_true(probe.wait_until(function ()
			return #calls >= 2
		end, { timeout = 0.8, interval = 0.01 }), 'expected transport open to be retried')

		child:cancel('test complete')
		cap_scope:cancel('test complete')
		fibers.perform(child:join_op())
		fibers.perform(cap_scope:join_op())
	end, { timeout = 2.0 })
end

local function fake_config_service(configs)
	return {
		start = function (conn)
			for service_id, payload in pairs(configs) do
				conn:retain({ 'cfg', service_id }, payload)
			end
			while true do sleep.sleep(3600) end
		end,
	}
end

local function fake_hal_service()
	return {
		start = function (conn)
			while true do sleep.sleep(3600) end
		end,
	}
end

local function make_loader(configs)
	return function (name)
		if name == 'config' then return fake_config_service(configs) end
		if name == 'hal' then return fake_hal_service() end
		return require('services.' .. name)
	end
end

function T.real_main_launches_modern_services_with_fake_hal_and_config_dependencies_delayed()
	runfibers.run(function (scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local configs = {
			net = net_cfg(),
			update = { schema = 'devicecode.update/1', components = { { component = 'cm5' } } },
			ui = ui_cfg(),
			fabric = fabric_cfg(),
		}
		local main_child = assert(scope:child())
		assert_true(scope:spawn(function ()
			mainmod.run(main_child, {
				env = 'dev',
				services_csv = 'hal,config,net,update,ui,fabric',
				bus = bus,
				service_loader = make_loader(configs),
			})
		end))

		-- Give config replay time to put dependent services into waiting states.
		assert_true(probe.wait_until(function ()
			local net = retained_payload(conn, net_topics.summary())
			local upd = conn:call(update_topics.update_manager_rpc('status'), {}, { timeout = 0.05 })
			return net and net.state == 'waiting_for_hal'
				and upd and upd.snapshot and upd.snapshot.state == 'waiting_for_job_store'
		end, { timeout = 0.8, interval = 0.01 }), 'expected real launch to reach dependency waiting states')

		local cap_scope = assert(scope:child())
		local net_calls = {}
		bind_network_config_apply(cap_scope, bus, net_calls)
		bind_fake_control_store(cap_scope, bus, {})
		retain_artifact_store_available(bus)
		bind_http_listen(cap_scope, bus, {})
		bind_raw_uart_open(cap_scope, bus, {})

		assert_true(probe.wait_until(function ()
			local net = retained_payload(conn, net_topics.summary())
			local upd = conn:call(update_topics.update_manager_rpc('status'), {}, { timeout = 0.05 })
			local ui = retained_payload(conn, { 'svc', 'ui', 'status' })
			local fab = retained_payload(conn, fabric_topics.svc_status())
			return net and net.state == 'running'
				and upd and upd.snapshot and upd.snapshot.state == 'running'
				and ui and ui.ready == true
				and fab and fab.state == 'running'
		end, { timeout = 1.2, interval = 0.01 }), 'expected delayed dependencies to admit modern services')
		assert_eq(#net_calls, 1)

		main_child:cancel('test complete')
		cap_scope:cancel('test complete')
		fibers.perform(main_child:join_op())
		fibers.perform(cap_scope:join_op())
	end, { timeout = 3.0 })
end

return T
