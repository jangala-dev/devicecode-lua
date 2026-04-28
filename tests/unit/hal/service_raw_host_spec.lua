local busmod      = require 'bus'
local safe        = require 'coxpcall'
local fibers      = require 'fibers'
local channel     = require 'fibers.channel'
local op          = require 'fibers.op'

local probe       = require 'tests.support.bus_probe'
local runfibers   = require 'tests.support.run_fibers'
local cap_sdk     = require 'services.hal.sdk.cap'

local hal_service = require 'services.hal'
local hal_types   = require 'services.hal.types.core'
local cap_types   = require 'services.hal.types.capabilities'

local T = {}

local function wait_payload(conn, topic, timeout)
	return probe.wait_payload(conn, topic, { timeout = timeout or 0.5 })
end

local function expect_no_message(conn, topic, timeout)
	timeout = timeout or 0.05
	local sub = conn:subscribe(topic)

	local which = fibers.perform(op.named_choice{
		msg     = sub:recv_op():wrap(function() return 'msg' end),
		timeout = require('fibers.sleep').sleep_op(timeout):wrap(function() return 'timeout' end),
	})

	sub:unsubscribe()
	assert(which == 'timeout', 'unexpected retained/publication on ' .. table.concat(topic, '/'))
end

local function patch_modules(patches, fn)
	local saved = {}
	for name, value in pairs(patches) do
		saved[name] = package.loaded[name]
		package.loaded[name] = value
	end

	local old_hal = package.loaded['services.hal']
	package.loaded['services.hal'] = nil

	local ok, res = safe.pcall(fn)

	package.loaded['services.hal'] = old_hal
	for name, old in pairs(saved) do
		package.loaded[name] = old
	end

	if not ok then
		error(res, 0)
	end

	return res
end

local function new_bootstrap_filesystem_manager()
	local manager = {}

	function manager.start(_logger, _dev_ev_ch, _cap_emit_ch)
		manager.scope = fibers.current_scope()
		return ''
	end

	function manager.apply_config(_self, cfg)
		manager.last_cfg = cfg
		return true, nil
	end

	function manager.stop(_self)
		-- Explicitly legacy: allowed by hal.lua.
	end

	return manager
end

local function new_rawprobe_manager()
	local manager = {
		scope = nil,
		dev_ev_ch = nil,
		control_ch = nil,
		last_device = nil,
		worker_started = false,
	}

	local function ensure_control_worker()
		if manager.worker_started then
			return
		end
		manager.worker_started = true

		local ok, err = manager.scope:spawn(function(scope)
			while true do
				local which, a = fibers.perform(fibers.named_choice{
					req  = manager.control_ch:get_op(),
					stop = scope:not_ok_op(),
				})

				if which == 'stop' then
					return
				end

				local req = a
				local reply, reply_err = hal_types.new.Reply(true, {
					verb  = req.verb,
					value = req.opts and req.opts.value,
					mode  = 'raw-host',
				})
				assert(reply, tostring(reply_err))

				local sent, send_err = fibers.perform(req.reply_ch:put_op(reply))
				assert(sent ~= false, tostring(send_err))
			end
		end)
		assert(ok, tostring(err))
	end

	function manager.start(_logger, dev_ev_ch, _cap_emit_ch)
		local child, err = fibers.current_scope():child()
		if not child then
			return tostring(err)
		end

		manager.scope = child
		manager.dev_ev_ch = dev_ev_ch
		return ''
	end

	function manager.stop_op(_self)
		return op.guard(function()
			if manager.scope then
				manager.scope:cancel('rawprobe stop')
				local st = fibers.perform(manager.scope:join_op())
				manager.scope = nil
				return op.always(st == 'ok' or st == 'cancelled', nil)
			end
			return op.always(true, nil)
		end)
	end

	function manager.apply_config_op(cfg)
		cfg = cfg or {}

		return op.guard(function()
			local action = cfg.op or 'add'

			if action == 'add' then
				manager.control_ch = channel.new()
				ensure_control_worker()

				local cap, cap_err = cap_types.new.Capability(
					cfg.cap_class or 'uart',
					cfg.cap_id or 'main',
					manager.control_ch,
					cfg.offerings or { 'open' }
				)
				assert(cap, tostring(cap_err))

				local meta = {
					provider  = cfg.provider or 'hal.test.rawprobe',
					source_id = cfg.source_id or 'uart_main',
					extra     = cfg.extra,
				}

				local dev, dev_err = hal_types.new.Device(
					cfg.device_class or 'uart',
					cfg.device_id or 'main',
					meta,
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

				local sent, send_err = fibers.perform(manager.dev_ev_ch:put_op(ev))
				assert(sent ~= false, tostring(send_err))
				return op.always(true, nil)
			end

			if action == 'remove' then
				if not manager.last_device then
					return op.always(true, nil)
				end

				local dev = manager.last_device
				local ev, ev_err = hal_types.new.DeviceEvent(
					'removed',
					dev.class,
					dev.id,
					dev.meta,
					dev.capabilities
				)
				assert(ev, tostring(ev_err))

				local sent, send_err = fibers.perform(manager.dev_ev_ch:put_op(ev))
				assert(sent ~= false, tostring(send_err))
				return op.always(true, nil)
			end

			return op.always(false, 'unsupported op: ' .. tostring(action))
		end)
	end

	return manager
end

local function with_real_hal(scope, patches, body)
	return patch_modules(patches, function()
		local bus = busmod.new()

		local ok_spawn, spawn_err = scope:spawn(function()
			hal_service.start(bus:connect(), {
				name = 'hal',
				env = 'test',
				heartbeat_s = 60.0,
			})
		end)
		assert(ok_spawn, tostring(spawn_err))

		return body(bus)
	end)
end

local function publish_hal_config(conn, cfg)
	conn:retain({ 'cfg', 'hal' }, {
		data = cfg,
	})
end

function T.hal_publishes_raw_host_source_meta_and_status_on_add()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local rawprobe   = new_rawprobe_manager()

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.rawprobe']   = rawprobe,
		}, function(bus)
			local reader = bus:connect()
			local admin  = bus:connect()

			publish_hal_config(admin, {
				schema = 'devicecode.config/hal/1',
				rawprobe = {
					op           = 'add',
					source_id    = 'uart_main',
					device_class = 'uart',
					device_id    = 'main',
					cap_class    = 'uart',
					cap_id       = 'main',
					offerings    = { 'open' },
					provider     = 'hal.test.rawprobe',
				},
			})

			local meta = wait_payload(reader, { 'raw', 'host', 'uart_main', 'meta' }, 0.5)
			assert(type(meta) == 'table')
			assert(meta.provider == 'hal.test.rawprobe')
			assert(meta.source_id == 'uart_main')
			assert(meta.source == 'uart_main')
			assert(meta.class == 'uart')
			assert(meta.id == 'main')

			local status = wait_payload(reader, { 'raw', 'host', 'uart_main', 'status' }, 0.5)
			assert(type(status) == 'table')
			assert(status.state == 'available')
			assert(status.available == true)
			assert(status.source == 'uart_main')
			assert(status.class == 'uart')
			assert(status.id == 'main')
		end)
	end)
end

function T.hal_publishes_raw_host_cap_meta_status_and_rpc_on_add()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local rawprobe   = new_rawprobe_manager()

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.rawprobe']   = rawprobe,
		}, function(bus)
			local reader = bus:connect()
			local admin  = bus:connect()

			publish_hal_config(admin, {
				schema = 'devicecode.config/hal/1',
				rawprobe = {
					op           = 'add',
					source_id    = 'uart_main',
					device_class = 'uart',
					device_id    = 'main',
					cap_class    = 'uart',
					cap_id       = 'main',
					offerings    = { 'open' },
					provider     = 'hal.test.rawprobe',
				},
			})

			local meta = wait_payload(reader, {
				'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'meta'
			}, 0.5)
			assert(type(meta) == 'table')
			assert(type(meta.offerings) == 'table')
			assert(meta.offerings.open == true)
			assert(meta.source_kind == 'host')
			assert(meta.source == 'uart_main')

			local status = wait_payload(reader, {
				'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'status'
			}, 0.5)
			assert(type(status) == 'table')
			assert(status.state == 'available')
			assert(status.available == true)
			assert(status.source_kind == 'host')
			assert(status.source == 'uart_main')

			local listener = cap_sdk.new_raw_host_cap_listener(bus:connect(), 'uart_main', 'uart', 'main')
			local ref, err = fibers.perform(listener:wait_for_cap_op())
			assert(ref, tostring(err))

			local reply, call_err = fibers.perform(ref:call_control_op('open', { value = 115200 }))
			assert(reply, tostring(call_err))
			assert(reply.ok == true)
			assert(type(reply.reason) == 'table')
			assert(reply.reason.verb == 'open')
			assert(reply.reason.value == 115200)
			assert(reply.reason.mode == 'raw-host')

			listener:close()
		end)
	end)
end

function T.hal_marks_raw_host_source_and_capability_removed_and_unretains_meta()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local rawprobe   = new_rawprobe_manager()

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.rawprobe']   = rawprobe,
		}, function(bus)
			local reader = bus:connect()
			local admin  = bus:connect()

			publish_hal_config(admin, {
				schema = 'devicecode.config/hal/1',
				rawprobe = {
					op           = 'add',
					source_id    = 'uart_main',
					device_class = 'uart',
					device_id    = 'main',
					cap_class    = 'uart',
					cap_id       = 'main',
					offerings    = { 'open' },
					provider     = 'hal.test.rawprobe',
				},
			})

			assert(type(wait_payload(reader, { 'raw', 'host', 'uart_main', 'status' }, 0.5)) == 'table')
			assert(type(wait_payload(reader, {
				'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'status'
			}, 0.5)) == 'table')

			publish_hal_config(admin, {
				schema = 'devicecode.config/hal/1',
				rawprobe = { op = 'remove' },
			})

            local source_status
            local ok = probe.wait_until(function()
                source_status = wait_payload(reader, { 'raw', 'host', 'uart_main', 'status' }, 0.05)
                return type(source_status) == 'table' and source_status.state == 'removed'
            end, {
                timeout = 0.5,
                interval = 0.01,
            })
            assert(ok, 'timed out waiting for raw host source status to become removed')
            assert(source_status.available == false)

            local cap_status
            ok = probe.wait_until(function()
                cap_status = wait_payload(reader, {
                    'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'status'
                }, 0.05)
                return type(cap_status) == 'table' and cap_status.state == 'removed'
            end, {
                timeout = 0.5,
                interval = 0.01,
            })
            assert(ok, 'timed out waiting for raw host capability status to become removed')
            assert(cap_status.available == false)
            assert(cap_status.source_kind == 'host')
            assert(cap_status.source == 'uart_main')

			expect_no_message(reader, { 'raw', 'host', 'uart_main', 'meta' }, 0.05)
			expect_no_message(reader, {
				'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'meta'
			}, 0.05)
		end)
	end)
end

function T.hal_keeps_legacy_public_capability_topics_for_compatibility()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local rawprobe   = new_rawprobe_manager()

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.rawprobe']   = rawprobe,
		}, function(bus)
			local reader = bus:connect()
			local admin  = bus:connect()

			publish_hal_config(admin, {
				schema = 'devicecode.config/hal/1',
				rawprobe = {
					op           = 'add',
					source_id    = 'uart_main',
					device_class = 'uart',
					device_id    = 'main',
					cap_class    = 'uart',
					cap_id       = 'main',
					offerings    = { 'open' },
					provider     = 'hal.test.rawprobe',
				},
			})

			local legacy_state = wait_payload(reader, { 'cap', 'uart', 'main', 'state' }, 0.5)
			assert(legacy_state == 'added')

			local curated_status = wait_payload(reader, { 'cap', 'uart', 'main', 'status' }, 0.5)
			assert(type(curated_status) == 'table')
			assert(curated_status.state == 'available')
			assert(curated_status.available == true)
			assert(curated_status.source_kind == 'host')
			assert(curated_status.source == 'uart_main')

			local legacy_meta = wait_payload(reader, { 'cap', 'uart', 'main', 'meta' }, 0.5)
			assert(type(legacy_meta) == 'table')
			assert(type(legacy_meta.offerings) == 'table')
			assert(legacy_meta.offerings.open == true)
		end)
	end)
end

return T
