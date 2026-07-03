local busmod     = require 'bus'
local safe       = require 'coxpcall'
local fibers     = require 'fibers'
local op         = require 'fibers.op'
local channel    = require 'fibers.channel'

local runfibers  = require 'tests.support.run_fibers'
local cap_sdk    = require 'services.hal.sdk.cap'
local core_types = require 'services.hal.types.core'
local cap_types  = require 'services.hal.types.capabilities'

local T = {}

local function patch_modules(patches, fn)
	local saved = {}
	for name, value in pairs(patches) do
		saved[name] = package.loaded[name]
		package.loaded[name] = value
	end

	local old_hal = package.loaded['services.hal']
	package.loaded['services.hal'] = nil

	local ok, a, b = safe.pcall(fn)

	package.loaded['services.hal'] = old_hal
	for name, old in pairs(saved) do
		package.loaded[name] = old
	end

	if not ok then
		error(a, 0)
	end

	return a, b
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
		-- Deliberately returns nothing: this is the legacy normalisation case.
	end

	return manager
end

local function new_capability_manager(opts)
	opts = opts or {}

	local manager = {
		name       = assert(opts.name, 'name required'),
		cap_class  = assert(opts.cap_class, 'cap_class required'),
		cap_id     = assert(opts.cap_id, 'cap_id required'),
		offerings  = opts.offerings or { 'echo' },
		apply_mode = opts.apply_mode or 'legacy',
		no_reply   = not not opts.no_reply,
		reply_fn   = opts.reply_fn,
		calls      = {},
		api_mode   = (opts.apply_mode == 'op') and 'op_only' or nil,
	}

	local control_ch = channel.new()
	local emitted = false

	local function emit_added()
		if emitted then return end
		emitted = true

		local cap, cap_err = cap_types.new.Capability(
			manager.cap_class,
			manager.cap_id,
			control_ch,
			manager.offerings
		)
		assert(cap, tostring(cap_err))

		local dev_ev, dev_err = core_types.new.DeviceEvent(
			'added',
			'testdev',
			manager.name,
			{},
			{ cap }
		)
		assert(dev_ev, tostring(dev_err))

		local sent, send_err = fibers.perform(manager.dev_ev_ch:put_op(dev_ev))
		assert(sent ~= false, tostring(send_err))
	end

	local function control_worker(scope)
		while true do
			local which, a, b = fibers.perform(fibers.named_choice{
				req  = control_ch:get_op(),
				stop = scope:not_ok_op(),
			})

			if which == 'stop' then
				return
			end

			local req = a
			manager.calls[#manager.calls + 1] = {
				verb = req.verb,
				opts = req.opts,
			}

			if manager.no_reply then
				-- Consume the request and deliberately never reply.
			else
				local ok, reason
				if manager.reply_fn then
					ok, reason = manager.reply_fn(req)
				else
					ok, reason = true, {
						manager = manager.name,
						verb    = req.verb,
						echo    = req.opts and req.opts.value,
					}
				end

				local reply, reply_err = core_types.new.Reply(ok, reason)
				assert(reply, tostring(reply_err))

				local sent, send_err = fibers.perform(req.reply_ch:put_op(reply))
				assert(sent ~= false, tostring(send_err))
			end
		end
	end

	if manager.apply_mode == 'op' then
		function manager.start_op(_logger, dev_ev_ch, _cap_emit_ch)
			return op.guard(function()
				manager.scope = fibers.current_scope()
				manager.dev_ev_ch = dev_ev_ch

				local ok, err = manager.scope:spawn(function(s)
					control_worker(s)
				end)
				if not ok then
					return op.always(false, tostring(err))
				end

				return op.always(true, nil)
			end)
		end

		function manager.apply_config_op(cfg)
			return op.guard(function()
				manager.last_cfg = cfg
				manager.apply_calls = (manager.apply_calls or 0) + 1
				emit_added()
				return op.always(true, nil)
			end)
		end

		function manager.shutdown_op(_timeout)
			return op.guard(function()
				manager.shutdown_calls = (manager.shutdown_calls or 0) + 1
				return op.always(true, nil)
			end)
		end

		function manager.terminate(reason)
			manager.terminate_calls = (manager.terminate_calls or 0) + 1
			manager.terminate_reason = reason
			if manager.scope then
				manager.scope:cancel(tostring(reason or 'terminated'))
			end
			return true, nil
		end

		function manager.fault_op()
			if manager.scope then
				return manager.scope:fault_op()
			end
			return op.never()
		end
	else
		function manager.start(_logger, dev_ev_ch, _cap_emit_ch)
			manager.scope = fibers.current_scope()
			manager.dev_ev_ch = dev_ev_ch

			local ok, err = manager.scope:spawn(function(s)
				control_worker(s)
			end)
			assert(ok, tostring(err))

			return ''
		end

		function manager.apply_config(_self, cfg)
			manager.last_cfg = cfg
			manager.apply_calls = (manager.apply_calls or 0) + 1
			emit_added()
			return true, nil
		end

		function manager.stop(_self)
			manager.stop_calls = (manager.stop_calls or 0) + 1
			-- Legacy-compatible nil return.
		end
	end

	return manager
end

local function new_hanging_start_manager()
	return {
		api_mode = 'op_only',

		start_op = function()
			return op.never()
		end,

		apply_config_op = function()
			return op.always(true, nil)
		end,

		shutdown_op = function()
			return op.always(true, nil)
		end,

		terminate = function()
			return true, nil
		end,

		fault_op = function()
			return op.never()
		end,
	}
end

local function new_hanging_apply_manager()
	local manager = {
		api_mode = 'op_only',
		started = false,
	}

	function manager.start_op(_logger, _dev_ev_ch, _cap_emit_ch)
		return op.guard(function()
			manager.started = true
			manager.scope = fibers.current_scope()
			return op.always(true, nil)
		end)
	end

	function manager.apply_config_op(_cfg)
		return op.never()
	end

	function manager.shutdown_op()
		return op.always(true, nil)
	end

	function manager.terminate(reason)
		manager.terminate_calls = (manager.terminate_calls or 0) + 1
		manager.terminate_reason = reason
		if manager.scope then
			manager.scope:cancel(tostring(reason or 'terminated'))
		end
		return true, nil
	end

	function manager.fault_op()
		if manager.scope then
			return manager.scope:fault_op()
		end
		return op.never()
	end

	return manager
end

local function with_real_hal(scope, patches, body, hal_opts)
	return patch_modules(patches, function()
		local hal = require 'services.hal'
		local bus = busmod.new()

		local opts = {
			name = 'hal',
			heartbeat_s = 60.0,
		}
		if hal_opts then
			for k, v in pairs(hal_opts) do
				opts[k] = v
			end
		end

		local ok_spawn, spawn_err = scope:spawn(function()
			hal.start(bus:connect(), opts)
		end)
		assert(ok_spawn, tostring(spawn_err))

		local probe_conn = bus:connect()
		return body(bus, probe_conn)
	end)
end

function T.non_legacy_managers_must_expose_op_methods()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local legacy_mgr = new_capability_manager{
			name = 'legacy_mgr',
			cap_class = 'legacy_cap',
			cap_id = 'cap1',
			apply_mode = 'legacy',
			offerings = { 'echo' },
		}

		-- Make this fixture explicitly strict, but leave apply_config_op absent.
		legacy_mgr.api_mode = 'op_only'

		function legacy_mgr.start_op(_logger, dev_ev_ch, _cap_emit_ch)
			return op.guard(function()
				legacy_mgr.scope = fibers.current_scope()
				legacy_mgr.dev_ev_ch = dev_ev_ch
				return op.always(true, nil)
			end)
		end

		function legacy_mgr.shutdown_op(_timeout)
			return op.guard(function()
				legacy_mgr.shutdown_calls = (legacy_mgr.shutdown_calls or 0) + 1
				return op.always(true, nil)
			end)
		end

		local ok, err = safe.pcall(function()
			with_real_hal(scope, {
				['services.hal.managers.filesystem'] = fs_manager,
				['services.hal.managers.legacy_mgr'] = legacy_mgr,
			}, function(bus, _probe_conn)
				local admin = bus:connect()
				admin:retain({ 'cfg', 'hal' }, {
					data = {
						schema = 'devicecode.config/hal/1',
						legacy_mgr = {},
					},
				})
				fibers.perform(require('fibers.sleep').sleep_op(0.05))
			end)
		end)

		assert(ok == false)
		assert(tostring(err):match('legacy_mgr'))
		assert(tostring(err):match('apply_config_op'))
	end)
end

function T.op_manager_methods_work_through_real_hal()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local op_mgr = new_capability_manager{
			name = 'op_mgr',
			cap_class = 'op_cap',
			cap_id = 'cap2',
			apply_mode = 'op',
			offerings = { 'echo' },
		}

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.op_mgr'] = op_mgr,
		}, function(bus, _probe_conn)
			local admin = bus:connect()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					op_mgr = {},
				},
			})

			local listener = cap_sdk.new_curated_cap_listener(bus:connect(), 'op_cap', 'cap2')
			local ref, err = fibers.perform(listener:wait_for_cap_op())
			assert(ref, tostring(err))
			assert(ref.call_control == nil)

			local reply, call_err = fibers.perform(ref:call_control_op('echo', { value = 7 }))
			assert(reply, tostring(call_err))
			assert(reply.ok == true)
			assert(type(reply.reason) == 'table')
			assert(reply.reason.echo == 7)
			assert(reply.reason.verb == 'echo')

			assert((op_mgr.apply_calls or 0) == 1)
			assert(#op_mgr.calls == 1)

			listener:close()
		end)
	end)
end


function T.strict_manager_shutdown_uses_shutdown_op()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local op_mgr = new_capability_manager{
			name = 'shutdown_mgr',
			cap_class = 'shutdown_cap',
			cap_id = 'cap_shutdown',
			apply_mode = 'op',
			offerings = { 'echo' },
		}

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.shutdown_mgr'] = op_mgr,
		}, function(bus)
			local admin = bus:connect()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					shutdown_mgr = {},
				},
			})

			local listener = cap_sdk.new_curated_cap_listener(bus:connect(), 'shutdown_cap', 'cap_shutdown')
			local ref, err = fibers.perform(listener:wait_for_cap_op())
			assert(ref, tostring(err))
			listener:close()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
				},
			})

			fibers.perform(require('fibers.sleep').sleep_op(0.05))

			assert((op_mgr.shutdown_calls or 0) == 1)
			assert(op_mgr.stop_calls == nil)
		end)
	end)
end

function T.legacy_manager_shutdown_uses_stop_compatibility()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local legacy_mgr = new_capability_manager{
			name = 'legacy_shutdown_mgr',
			cap_class = 'legacy_shutdown_cap',
			cap_id = 'cap_legacy_shutdown',
			apply_mode = 'legacy',
			offerings = { 'echo' },
		}

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.legacy_shutdown_mgr'] = legacy_mgr,
		}, function(bus)
			local admin = bus:connect()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					legacy_shutdown_mgr = {},
				},
			})

			local listener = cap_sdk.new_curated_cap_listener(bus:connect(), 'legacy_shutdown_cap', 'cap_legacy_shutdown')
			local ref, err = fibers.perform(listener:wait_for_cap_op())
			assert(ref, tostring(err))
			listener:close()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
				},
			})

			fibers.perform(require('fibers.sleep').sleep_op(0.05))

			assert((legacy_mgr.stop_calls or 0) == 1)
			assert(legacy_mgr.shutdown_calls == nil)
		end)
	end)
end

function T.op_manager_start_timeout_does_not_block_later_config()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local hanging = new_hanging_start_manager()
		local good = new_capability_manager{
			name = 'good_mgr',
			cap_class = 'good_cap',
			cap_id = 'cap_ok',
			apply_mode = 'op',
			offerings = { 'echo' },
		}

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.hanging_mgr'] = hanging,
			['services.hal.managers.good_mgr'] = good,
		}, function(bus)
			local admin = bus:connect()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					hanging_mgr = {},
				},
			})

			fibers.perform(require('fibers.sleep').sleep_op(0.05))

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					good_mgr = {},
				},
			})

			local listener = cap_sdk.new_curated_cap_listener(bus:connect(), 'good_cap', 'cap_ok')
			local ref, err = fibers.perform(listener:wait_for_cap_op())
			assert(ref, tostring(err))

			listener:close()
		end, {
			manager_start_timeout_s = 0.02,
			manager_apply_timeout_s = 0.02,
		})
	end, { timeout = 2.0 })
end

function T.op_manager_apply_timeout_does_not_block_later_config()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local hanging_apply = new_hanging_apply_manager()
		local good = new_capability_manager{
			name = 'good_apply_mgr',
			cap_class = 'good_apply_cap',
			cap_id = 'cap_ok',
			apply_mode = 'op',
			offerings = { 'echo' },
		}

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.hanging_apply'] = hanging_apply,
			['services.hal.managers.good_apply_mgr'] = good,
		}, function(bus)
			local admin = bus:connect()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					hanging_apply = {},
				},
			})

			fibers.perform(require('fibers.sleep').sleep_op(0.05))

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					good_apply_mgr = {},
				},
			})

			local listener = cap_sdk.new_curated_cap_listener(bus:connect(), 'good_apply_cap', 'cap_ok')
			local ref, err = fibers.perform(listener:wait_for_cap_op())
			assert(ref, tostring(err))

			assert(hanging_apply.started == true)

			listener:close()
		end, {
			manager_start_timeout_s = 0.02,
			manager_apply_timeout_s = 0.02,
		})
	end, { timeout = 2.0 })
end


function T.op_manager_apply_timeout_reports_pending_not_failed()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local hanging_apply = new_hanging_apply_manager()

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.hanging_apply'] = hanging_apply,
		}, function(bus)
			local admin = bus:connect()
			local reader = bus:connect()
			local end_sub = reader:subscribe({ 'obs', 'v1', 'hal', 'event', 'config_end' }, { queue_len = 8, full = 'drop_oldest' })
			local log_sub = reader:subscribe({ 'obs', 'v1', 'hal', 'event', 'log' }, { queue_len = 16, full = 'drop_oldest' })

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					hanging_apply = {},
				},
			})

			local end_msg
			for _ = 1, 8 do
				local which, msg = fibers.perform(op.named_choice({
					msg = end_sub:recv_op(),
					timeout = require('fibers.sleep').sleep_op(0.2):wrap(function () return nil end),
				}))
				if which == 'msg' and msg and msg.payload and msg.payload.pending_managers then
					end_msg = msg
					break
				end
			end
			assert(end_msg and end_msg.payload, 'expected config_end with pending manager')
			assert(end_msg.payload.ok == true, 'pending admitted manager should not make config_end fail')
			assert(end_msg.payload.degraded == true, 'pending manager should mark config degraded')
			assert(end_msg.payload.pending_managers[1] == 'hanging_apply')

			local saw_pending = false
			local saw_failed = false
			for _ = 1, 8 do
				local which, msg = fibers.perform(op.named_choice({
					msg = log_sub:recv_op(),
					timeout = require('fibers.sleep').sleep_op(0.05):wrap(function () return nil end),
				}))
				if which ~= 'msg' then break end
				local p = msg and msg.payload or {}
				if p.what == 'manager_apply_pending_timeout' and p.manager == 'hanging_apply' then saw_pending = true end
				if p.what == 'manager_apply_failed' and p.manager == 'hanging_apply' then saw_failed = true end
			end
			assert(saw_pending == true, 'expected manager_apply_pending_timeout log')
			assert(saw_failed == false, 'pending admitted manager must not be logged as failed')

			end_sub:unsubscribe()
			log_sub:unsubscribe()
		end, {
			manager_start_timeout_s = 0.02,
			manager_apply_timeout_s = 0.02,
		})
	end, { timeout = 2.0 })
end

function T.unsupported_control_verb_returns_no_route()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local mgr = new_capability_manager{
			name = 'verb_mgr',
			cap_class = 'verb_cap',
			cap_id = 'cap3',
			apply_mode = 'op',
			offerings = { 'echo' },
		}

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.verb_mgr'] = mgr,
		}, function(bus, _probe_conn)
			local admin = bus:connect()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					verb_mgr = {},
				},
			})

			local listener = cap_sdk.new_curated_cap_listener(bus:connect(), 'verb_cap', 'cap3')
			local ref, err = fibers.perform(listener:wait_for_cap_op())
			assert(ref, tostring(err))

			local reply, call_err = fibers.perform(ref:call_control_op('missing', {}))
			assert(reply == nil)
			assert(call_err == 'no_route' or tostring(call_err):match('no_route'))

			listener:close()
		end)
	end)
end

function T.capability_no_reply_is_completed_by_hal_control_timeout()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local mgr = new_capability_manager{
			name = 'timeout_mgr',
			cap_class = 'timeout_cap',
			cap_id = 'cap4',
			apply_mode = 'op',
			offerings = { 'echo' },
			no_reply = true,
		}

		with_real_hal(scope, {
			['services.hal.managers.filesystem'] = fs_manager,
			['services.hal.managers.timeout_mgr'] = mgr,
		}, function(bus, _probe_conn)
			local admin = bus:connect()

			admin:retain({ 'cfg', 'hal' }, {
				data = {
					schema = 'devicecode.config/hal/1',
					timeout_mgr = {},
				},
			})

			local listener = cap_sdk.new_curated_cap_listener(bus:connect(), 'timeout_cap', 'cap4')
			local ref, wait_err = fibers.perform(listener:wait_for_cap_op())
			assert(ref, tostring(wait_err))

			local t0 = fibers.now()

			local reply, err = fibers.perform(ref:call_control_op('echo', { value = 9 }, {
				timeout = 0.5,
				backoff = 0.01,
				backoff_max = 0.01,
			}))

			local elapsed = fibers.now() - t0

			assert(reply ~= nil, tostring(err))
			assert(err == nil)
			assert(reply.ok == false)
			assert(type(reply.reason) == 'string')
			assert(reply.reason:match('timeout'))
			assert(elapsed < 0.25, 'request appears to have waited for client timeout, not HAL timeout')
			assert(#mgr.calls == 1)

			listener:close()
		end, {
			control_timeout_s = 0.03,
		})
	end, { timeout = 2.0 })
end

function T.strict_manager_contract_requires_terminate_and_fault_op()
	runfibers.run(function(scope)
		local fs_manager = new_bootstrap_filesystem_manager()
		local strict_mgr = {
			api_mode = 'op_only',
			start_op = function() return op.always(true, nil) end,
			apply_config_op = function() return op.always(true, nil) end,
			shutdown_op = function() return op.always(true, nil) end,
			-- terminate and fault_op are deliberately absent.
		}

		local ok, err = safe.pcall(function()
			with_real_hal(scope, {
				['services.hal.managers.filesystem'] = fs_manager,
				['services.hal.managers.strict_mgr'] = strict_mgr,
			}, function(bus, _probe_conn)
				local admin = bus:connect()
				admin:retain({ 'cfg', 'hal' }, {
					data = {
						schema = 'devicecode.config/hal/1',
						strict_mgr = {},
					},
				})
				fibers.perform(require('fibers.sleep').sleep_op(0.05))
			end)
		end)

		assert(ok == false)
		assert(tostring(err):match('strict_mgr'))
		assert(tostring(err):match('terminate'))
	end)
end

function T.strict_hal_managers_do_not_use_perform_raw()
	local paths = {
		'../src/services/hal/managers/artifact_store.lua',
		'../src/services/hal/managers/control_store.lua',
		'../src/services/hal/managers/signature_verify.lua',
		'../src/services/hal/managers/uart.lua',
	}

	for _, path in ipairs(paths) do
		local f = assert(io.open(path, 'r'))
		local s = f:read('*a')
		f:close()
		assert(not s:find('perform_raw', 1, true), path .. ' uses perform_raw')
	end
end

return T
