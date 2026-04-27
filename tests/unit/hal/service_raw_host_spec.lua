local busmod    = require 'bus'
local fibers    = require 'fibers'
local channel   = require 'fibers.channel'

local probe     = require 'tests.support.bus_probe'
local runfibers = require 'tests.support.run_fibers'

local hal_service = require 'services.hal'
local hal_types   = require 'services.hal.types.core'
local cap_types   = require 'services.hal.types.capabilities'

local T = {}

local function wait_payload(conn, topic, timeout)
	return probe.wait_payload(conn, topic, { timeout = timeout or 0.5 })
end

local function wait_until(fn, timeout, interval)
	return probe.wait_until(fn, {
		timeout = timeout or 1.0,
		interval = interval or 0.01,
	})
end

local function topic_equal(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function install_fake_hal_managers(state)
	package.loaded['services.hal.managers.filesystem'] = nil
	package.loaded['services.hal.managers.rawprobe'] = nil

	package.preload['services.hal.managers.filesystem'] = function()
		local manager = {
			started = false,
			scope = nil,
			logger = nil,
		}

		function manager.start(logger, dev_ev_ch, cap_emit_ch)
			manager.logger = logger
			local scope_obj, err = fibers.current_scope():child()
			if not scope_obj then
				return tostring(err)
			end
			manager.scope = scope_obj
			manager.started = true
			return ""
		end

		function manager.stop()
			if manager.scope then
				manager.scope:cancel('test stop')
				fibers.perform(manager.scope:join_op())
			end
			manager.started = false
			return true, ""
		end

		function manager.apply_config(_cfg)
			return true, ""
		end

		return manager
	end

	package.preload['services.hal.managers.rawprobe'] = function()
		local manager = {
			started = false,
			scope = nil,
			dev_ev_ch = nil,
			logger = nil,
			last_device = nil,
		}

		function manager.start(logger, dev_ev_ch, cap_emit_ch)
			manager.logger = logger
			manager.dev_ev_ch = dev_ev_ch

			local scope_obj, err = fibers.current_scope():child()
			if not scope_obj then
				return tostring(err)
			end
			manager.scope = scope_obj
			manager.started = true
			return ""
		end

		function manager.stop()
			if manager.scope then
				manager.scope:cancel('test stop')
				fibers.perform(manager.scope:join_op())
			end
			manager.started = false
			return true, ""
		end

		function manager.apply_config(cfg)
			cfg = cfg or {}
			local op_name = cfg.op or 'add'

			if op_name == 'add' then
				local control_ch = channel.new()
				local cap, cap_err = cap_types.new.Capability(
					cfg.cap_class or 'uart',
					cfg.cap_id or 'main',
					control_ch,
					cfg.offerings or { 'open' }
				)
				assert(cap, tostring(cap_err))

				local dev_meta = {
					provider = cfg.provider or 'hal.test.rawprobe',
					raw_source_id = cfg.raw_source_id,
					source_id = cfg.source_id,
					source = cfg.source,
					extra = cfg.extra,
				}

				local dev, dev_err = hal_types.new.Device(
					cfg.device_class or 'uart',
					cfg.device_id or 'main',
					dev_meta,
					{ cap }
				)
				assert(dev, tostring(dev_err))
				manager.last_device = dev

				local ev, ev_err = hal_types.new.DeviceEvent(
					'added',
					dev.class,
					dev.id,
					dev.meta,
					dev.capabilities
				)
				assert(ev, tostring(ev_err))
				manager.dev_ev_ch:put(ev)
				return true, ""
			end

			if op_name == 'remove' then
				local dev = manager.last_device
				if not dev then
					return true, ""
				end

				local ev, ev_err = hal_types.new.DeviceEvent(
					'removed',
					dev.class,
					dev.id,
					dev.meta,
					dev.capabilities
				)
				assert(ev, tostring(ev_err))
				manager.dev_ev_ch:put(ev)
				return true, ""
			end

			return false, "unsupported op: " .. tostring(op_name)
		end

		return manager
	end
end

local function start_hal(scope, bus)
	local ok_spawn, err = scope:spawn(function()
		hal_service.start(bus:connect(), {
			name = 'hal',
			env = 'test',
			heartbeat_s = 60.0,
		})
	end)
	assert(ok_spawn, tostring(err))
end

local function publish_hal_config(conn, cfg)
	conn:retain({ 'cfg', 'hal' }, {
		data = cfg,
	})
end

function T.hal_publishes_raw_host_source_meta_and_status_on_add()
	runfibers.run(function(scope)
		local bus    = busmod.new()
		local reader = bus:connect()
		local cfgc   = bus:connect()

		install_fake_hal_managers({})
		start_hal(scope, bus)

		publish_hal_config(cfgc, {
			schema = 'devicecode.config/hal/1',
			rawprobe = {
				op = 'add',
				raw_source_id = 'uart_main',
				device_class = 'uart',
				device_id = 'main',
				cap_class = 'uart',
				cap_id = 'main',
				offerings = { 'open' },
				provider = 'hal.test.rawprobe',
			},
		})

		local meta = wait_payload(reader, { 'raw', 'host', 'uart-main', 'meta' }, 0.5)
		assert(type(meta) == 'table')
		assert(meta.provider == 'hal.test.rawprobe')
		assert(meta.source == 'uart_main')
		assert(meta.device_class == 'uart')
		assert(meta.device_id == 'main')
		assert(type(meta.legacy_device) == 'table')
		assert(meta.legacy_device.class == 'uart')
		assert(meta.legacy_device.id == 'main')

		local status = wait_payload(reader, { 'raw', 'host', 'uart-main', 'status' }, 0.5)
		assert(type(status) == 'table')
		assert(status.state == 'available')
		assert(status.source == 'uart_main')
		assert(status.id == 'main')
	end, { timeout = 2.0 })
end

function T.hal_publishes_structured_raw_host_cap_status_and_meta_on_add()
	runfibers.run(function(scope)
		local bus    = busmod.new()
		local reader = bus:connect()
		local cfgc   = bus:connect()

		install_fake_hal_managers({})
		start_hal(scope, bus)

		publish_hal_config(cfgc, {
			schema = 'devicecode.config/hal/1',
			rawprobe = {
				op = 'add',
				raw_source_id = 'uart_main',
				device_class = 'uart',
				device_id = 'main',
				cap_class = 'uart',
				cap_id = 'main',
				offerings = { 'open' },
				provider = 'hal.test.rawprobe',
			},
		})

		local status = wait_payload(reader, {
			'raw', 'host', 'uart-main', 'cap', 'uart', 'main', 'status'
		}, 0.5)

		assert(type(status) == 'table')
		assert(status.state == 'available')
		assert(status.source == 'uart_main')
		assert(status.class == 'uart')
		assert(status.id == 'main')

		local meta = wait_payload(reader, {
			'raw', 'host', 'uart-main', 'cap', 'uart', 'main', 'meta'
		}, 0.5)

		assert(type(meta) == 'table')
		assert(meta.provider == 'hal.test.rawprobe')
		assert(meta.source == 'uart_main')
		assert(type(meta.offerings) == 'table')
		assert(meta.offerings.open == true)
		assert(type(meta.legacy_cap) == 'table')
		assert(meta.legacy_cap.class == 'uart')
		assert(meta.legacy_cap.id == 'main')
	end, { timeout = 2.0 })
end

function T.hal_marks_raw_host_source_and_capability_unavailable_on_remove()
	runfibers.run(function(scope)
		local bus    = busmod.new()
		local reader = bus:connect()
		local cfgc   = bus:connect()

		install_fake_hal_managers({})
		start_hal(scope, bus)

		publish_hal_config(cfgc, {
			schema = 'devicecode.config/hal/1',
			rawprobe = {
				op = 'add',
				raw_source_id = 'uart_main',
				device_class = 'uart',
				device_id = 'main',
				cap_class = 'uart',
				cap_id = 'main',
				offerings = { 'open' },
				provider = 'hal.test.rawprobe',
			},
		})

		assert(type(wait_payload(reader, { 'raw', 'host', 'uart-main', 'status' }, 0.5)) == 'table')
		assert(type(wait_payload(reader, {
			'raw', 'host', 'uart-main', 'cap', 'uart', 'main', 'status'
		}, 0.5)) == 'table')

		publish_hal_config(cfgc, {
			schema = 'devicecode.config/hal/1',
			rawprobe = {
				op = 'remove',
			},
		})

		assert(wait_until(function()
			local ok1, source_status = pcall(function()
				return wait_payload(reader, { 'raw', 'host', 'uart-main', 'status' }, 0.05)
			end)
			if not ok1 or type(source_status) ~= 'table' then return false end
			if source_status.state ~= 'unavailable' then return false end
			if source_status.reason ~= 'removed' then return false end

			local ok2, cap_status = pcall(function()
				return wait_payload(reader, {
					'raw', 'host', 'uart-main', 'cap', 'uart', 'main', 'status'
				}, 0.05)
			end)
			if not ok2 or type(cap_status) ~= 'table' then return false end
			return cap_status.state == 'unavailable'
				and cap_status.reason == 'removed'
				and cap_status.source == 'uart_main'
				and cap_status.class == 'uart'
				and cap_status.id == 'main'
		end, 1.0, 0.02))
	end, { timeout = 2.0 })
end

function T.hal_keeps_legacy_public_capability_registration_topics_for_compatibility()
	runfibers.run(function(scope)
		local bus    = busmod.new()
		local reader = bus:connect()
		local cfgc   = bus:connect()

		install_fake_hal_managers({})
		start_hal(scope, bus)

		publish_hal_config(cfgc, {
			schema = 'devicecode.config/hal/1',
			rawprobe = {
				op = 'add',
				raw_source_id = 'uart_main',
				device_class = 'uart',
				device_id = 'main',
				cap_class = 'uart',
				cap_id = 'main',
				offerings = { 'open' },
				provider = 'hal.test.rawprobe',
			},
		})

		local legacy_state = wait_payload(reader, { 'cap', 'uart', 'main', 'state' }, 0.5)
		assert(legacy_state == 'added')

		local legacy_meta = wait_payload(reader, { 'cap', 'uart', 'main', 'meta' }, 0.5)
		assert(type(legacy_meta) == 'table')
		assert(type(legacy_meta.offerings) == 'table')
		assert(legacy_meta.offerings.open == true)
	end, { timeout = 2.0 })
end

function T.hal_legacy_cap_sdk_listener_still_works_end_to_end()
	runfibers.run(function(scope)
		local bus    = busmod.new()
		local cfgc   = bus:connect()
		local client = bus:connect()

		install_fake_hal_managers({})
		start_hal(scope, bus)

		local cap_sdk = require 'services.hal.sdk.cap'
		local listener = cap_sdk.new_cap_listener(client, 'uart', 'main')

		local got_cap, got_err
		local ok, err = scope:spawn(function()
			got_cap, got_err = listener:wait_for_cap({ timeout = 0.5 })
		end)
		assert(ok, tostring(err))

		publish_hal_config(cfgc, {
			schema = 'devicecode.config/hal/1',
			rawprobe = {
				op = 'add',
				raw_source_id = 'uart_main',
				device_class = 'uart',
				device_id = 'main',
				cap_class = 'uart',
				cap_id = 'main',
				offerings = { 'open' },
				provider = 'hal.test.rawprobe',
			},
		})

		assert(wait_until(function()
			return got_cap ~= nil
		end, 1.0, 0.01))

		assert(got_err == '')
		assert(got_cap.class == 'uart')
		assert(got_cap.id == 'main')

		listener:close()
	end, { timeout = 2.0 })
end

return T
