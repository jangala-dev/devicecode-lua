local fibers = require 'fibers'
local busmod = require 'bus'

local net_service = require 'services.net.service'
local net_config = require 'services.net.config'
local net_topics = require 'services.net.topics'
local update_service = require 'services.update.service'
local update_topics = require 'services.update.topics'
local probe = require 'tests.support.bus_probe'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end return v end

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

local function bind_network_config_apply(scope, bus, calls)
	local conn = bus:connect()
	local ep = assert(conn:bind({ 'cap', 'network-config', 'main', 'rpc', 'apply' }, { queue_len = 8 }))
	local ok, err = scope:spawn(function ()
		while true do
			local req = fibers.perform(ep:recv_op())
			if req == nil then return end
			local payload = req.payload or {}
			calls[#calls + 1] = payload
			req:reply({
				ok = true,
				reason = {
					ok = true,
					applied = true,
					changed = true,
					backend = 'test-network-config',
					intent_rev = payload.intent and payload.intent.rev,
				},
			})
		end
	end)
	assert_true(ok, err)
	conn:retain({ 'cap', 'network-config', 'main', 'status' }, {
		schema = 'devicecode.cap.status/1',
		state = 'available',
		available = true,
	})
	return conn
end

local function bind_fake_control_store(scope, bus, backing)
	backing = backing or {}
	local conn = bus:connect()
	for _, method in ipairs({ 'list', 'get', 'put', 'delete' }) do
		local loop_method = method
		local ep = assert(conn:bind({ 'cap', 'control-store', 'update', 'rpc', loop_method }, { queue_len = 8 }))
		local ok, err = scope:spawn(function ()
			while true do
				local req = fibers.perform(ep:recv_op())
				if req == nil then return end
				local p = req.payload or {}
				if loop_method == 'list' then
					local keys = {}
					local prefix = p.prefix or ''
					for k in pairs(backing) do
						if k:sub(1, #prefix) == prefix then keys[#keys + 1] = k end
					end
					table.sort(keys)
					req:reply({ ok = true, reason = keys })
				elseif loop_method == 'get' then
					if backing[p.key] == nil then
						req:reply({ ok = false, reason = 'not found' })
					else
						req:reply({ ok = true, reason = backing[p.key] })
					end
				elseif loop_method == 'put' then
					backing[p.key] = p.data
					req:reply({ ok = true, reason = nil })
				elseif loop_method == 'delete' then
					backing[p.key] = nil
					req:reply({ ok = true, reason = nil })
				end
			end
		end)
		assert_true(ok, err)
	end
	conn:retain({ 'cap', 'control-store', 'update', 'status' }, {
		schema = 'devicecode.cap.status/1',
		state = 'available',
		available = true,
	})
	return conn
end

local function retain_artifact_store_available(bus)
	local conn = bus:connect()
	conn:retain({ 'cap', 'artifact-store', 'main', 'status' }, {
		schema = 'devicecode.cap.status/1',
		state = 'available',
		available = true,
	})
	return conn
end

function tests.test_net_and_update_wait_for_delayed_hal_capabilities_then_recover()
	fibers.run(function (root_scope)
		local bus = busmod.new()
		retain_artifact_store_available(bus)

		local net_conn = bus:connect()
		local update_conn = bus:connect()
		local reader = bus:connect()
		local caller = bus:connect()

		local net_child = assert(root_scope:child())
		local ok_net, net_err = net_child:spawn(function (scope)
			net_service.run(scope, {
				conn = net_conn,
				config = net_cfg(),
				rev = 100,
				observe = false,
			})
		end)
		assert_true(ok_net, net_err)

		local update_child = assert(root_scope:child())
		local ok_update, update_err = update_child:spawn(function (scope)
			update_service.run(scope, {
				conn = update_conn,
				service_id = 'update',
				watch_config = false,
				job_store_kind = 'control-store',
				config = { schema = 'devicecode.update/1', components = { { component = 'cm5' } } },
			})
		end)
		assert_true(ok_update, update_err)

		local net_view = reader:retained_view(net_topics.summary())
		local net_waiting = probe.wait_versioned_until('net waits for delayed network-config',
			function () return net_view:version() end,
			function (seen) return net_view:changed_op(seen) end,
			function ()
				local msg = net_view:get(net_topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'waiting_for_hal'
					and payload.dependencies and payload.dependencies.network_config
					and payload.dependencies.network_config.available == false
					and payload.pending and payload.pending.network_apply
					and payload or nil
			end,
			{ timeout = 0.7 })
		assert_eq(net_waiting.reason, 'network_config_unavailable')
		assert_eq(net_waiting.pending.network_apply.rev, 100)

		assert_true(probe.wait_until(function ()
			local status = caller:call(update_topics.update_manager_rpc('status'), {}, { timeout = 0.05 })
			local snap = status and status.snapshot
			return snap and snap.state == 'waiting_for_job_store'
				and snap.dependencies and snap.dependencies.job_store
				and snap.dependencies.job_store.available == false
				and snap.pending and snap.pending.runtime
				and snap.pending.runtime.dependency == 'job_store'
		end, { timeout = 0.7, interval = 0.01 }), 'update should wait for delayed control-store')

		local cap_scope = assert(root_scope:child())
		local net_calls = {}
		bind_network_config_apply(cap_scope, bus, net_calls)
		bind_fake_control_store(cap_scope, bus, {})

		local net_running = probe.wait_versioned_until('net applies after delayed network-config appears',
			function () return net_view:version() end,
			function (seen) return net_view:changed_op(seen) end,
			function ()
				local msg = net_view:get(net_topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'running'
					and payload.apply and payload.apply.state == 'applied'
					and payload.dependencies.network_config.available == true
					and payload or nil
			end,
			{ timeout = 0.8 })
		assert_eq(#net_calls, 1)
		assert_eq(net_calls[1].intent.rev, 100)
		assert_eq(net_running.pending and net_running.pending.network_apply, nil)

		assert_true(probe.wait_until(function ()
			local status = caller:call(update_topics.update_manager_rpc('status'), {}, { timeout = 0.05 })
			local snap = status and status.snapshot
			return snap and snap.state == 'running'
				and snap.dependencies and snap.dependencies.job_store
				and snap.dependencies.job_store.available == true
				and (not snap.pending or snap.pending.runtime == nil)
		end, { timeout = 0.8, interval = 0.01 }), 'update should start after delayed control-store appears')

		net_view:close()
		net_child:cancel('test complete')
		update_child:cancel('test complete')
		cap_scope:cancel('test complete')
		fibers.perform(net_child:join_op())
		fibers.perform(update_child:join_op())
		fibers.perform(cap_scope:join_op())
	end)
end

return tests
