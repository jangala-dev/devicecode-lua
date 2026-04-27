-- services/hal/managers/uart.lua
--
-- UART HAL manager.
--
-- Config shape:
--   uart = {
--     serial_ports = {
--       { name = 'uart0', path = '/dev/ttyAMA0', baud = 115200, mode = '8N1' },
--       ...
--     }
--   }

local uart_driver = require 'services.hal.drivers.uart'
local hal_types   = require 'services.hal.types.core'

local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'

local STOP_TIMEOUT = 5.0
local TRACE_MAX    = 256

local function dlog(logger, level, payload)
	if logger and logger[level] then
		logger[level](logger, payload)
	end
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function copy_trace(trace)
	local out = {}
	for i = 1, #(trace or {}) do
		local src = trace[i]
		local rec = {}
		for k, v in pairs(src or {}) do
			rec[k] = v
		end
		out[i] = rec
	end
	return out
end

local function count_drivers(drivers)
	local n = 0
	for _ in pairs(drivers or {}) do n = n + 1 end
	return n
end

local UARTManager = {
	started     = false,
	scope       = nil,
	logger      = nil,
	dev_ev_ch   = nil,
	cap_emit_ch = nil,
	drivers     = {},
	_trace      = {},
	_trace_seq  = 0,
}

local function trace_push(self, what, fields)
	self._trace_seq = (self._trace_seq or 0) + 1

	local rec = {
		seq  = self._trace_seq,
		t    = fibers.now(),
		what = what,
	}

	for k, v in pairs(fields or {}) do
		rec[k] = v
	end

	local tr = self._trace or {}
	tr[#tr + 1] = rec
	if #tr > TRACE_MAX then
		table.remove(tr, 1)
	end
	self._trace = tr
end

local function reset_runtime_state(scope_ref)
	if scope_ref ~= nil and UARTManager.scope ~= scope_ref then
		return
	end

	trace_push(UARTManager, 'manager.reset_runtime_state', {
		started      = UARTManager.started,
		driver_count = count_drivers(UARTManager.drivers),
	})

	UARTManager.started     = false
	UARTManager.scope       = nil
	UARTManager.logger      = nil
	UARTManager.dev_ev_ch   = nil
	UARTManager.cap_emit_ch = nil
	UARTManager.drivers     = {}
end

local function same_spec(a, b)
	if not a or not b then return false end
	return a.name == b.name
		and a.path == b.path
		and a.baud == b.baud
		and a.mode == b.mode
end

local function normalise_config(cfg)
	if type(cfg) ~= 'table' then
		return nil, 'uart config must be a table'
	end

	local serial_ports = cfg.serial_ports
	if type(serial_ports) ~= 'table' then
		return nil, 'uart.serial_ports must be an array'
	end

	local out = {}
	for i = 1, #serial_ports do
		local rec = serial_ports[i]
		if type(rec) ~= 'table' then
			return nil, ('uart.serial_ports[%d] must be a table'):format(i)
		end

		local name = rec.name
		local path = rec.path
		if type(name) ~= 'string' or name == '' then
			return nil, ('uart.serial_ports[%d].name must be a non-empty string'):format(i)
		end
		if type(path) ~= 'string' or path == '' then
			return nil, ('uart.serial_ports[%d].path must be a non-empty string'):format(i)
		end
		if out[name] ~= nil then
			return nil, ('uart serial port name duplicated: %s'):format(name)
		end

		local baud = rec.baud
		if baud ~= nil then
			if type(baud) ~= 'number' or baud <= 0 or baud % 1 ~= 0 then
				return nil, ('uart.serial_ports[%d].baud must be a positive integer'):format(i)
			end
			baud = math.floor(baud)
		end

		local mode = rec.mode
		if mode ~= nil then
			if type(mode) ~= 'string' or mode == '' then
				return nil, ('uart.serial_ports[%d].mode must be a non-empty string'):format(i)
			end
		end

		out[name] = {
			name = name,
			path = path,
			baud = baud,
			mode = mode,
		}
	end

	return out, ''
end

---@class UARTManagerRecord
---@field driver any
---@field spec table
---@field capabilities Capability[]

local function debug_driver_snapshot(rec)
	if not rec then return nil end

	local driver_snapshot
	if rec.driver and type(rec.driver.debug_snapshot) == 'function' then
		driver_snapshot = rec.driver:debug_snapshot()
	end

	return {
		spec = rec.spec and {
			name = rec.spec.name,
			path = rec.spec.path,
			baud = rec.spec.baud,
			mode = rec.spec.mode,
		} or nil,
		has_driver = rec.driver ~= nil,
		has_caps   = rec.capabilities ~= nil,
		driver     = driver_snapshot,
	}
end

function UARTManager.debug_snapshot()
	local drivers = {}

	for name, rec in pairs(UARTManager.drivers or {}) do
		drivers[name] = debug_driver_snapshot(rec)
	end

	local scope_status = nil
	if UARTManager.scope and UARTManager.scope.status then
		local st, primary = UARTManager.scope:status()
		scope_status = {
			state   = st,
			primary = tostring(primary),
		}
	end

	return {
		started      = UARTManager.started,
		scope_status = scope_status,
		driver_count = count_drivers(UARTManager.drivers),
		drivers      = drivers,
		trace        = copy_trace(UARTManager._trace),
	}
end

local function emit_added(name, spec, capabilities)
	trace_push(UARTManager, 'manager.emit_added.begin', {
		cap_id = name,
		path   = spec.path,
	})

	local ev, err = hal_types.new.DeviceEvent('added', 'uart', name, {
		path = spec.path,
		baud = spec.baud,
		mode = spec.mode,
	}, capabilities)

	if not ev then
		trace_push(UARTManager, 'manager.emit_added.failed', {
			cap_id = name,
			err    = tostring(err),
		})
		return nil, tostring(err)
	end

	UARTManager.dev_ev_ch:put(ev)

	trace_push(UARTManager, 'manager.emit_added.ok', {
		cap_id = name,
	})
	return true, nil
end

local function emit_removed(name)
	trace_push(UARTManager, 'manager.emit_removed.begin', {
		cap_id = name,
	})

	local ev, err = hal_types.new.DeviceEvent('removed', 'uart', name, {}, {})
	if not ev then
		trace_push(UARTManager, 'manager.emit_removed.failed', {
			cap_id = name,
			err    = tostring(err),
		})
		return nil, tostring(err)
	end

	UARTManager.dev_ev_ch:put(ev)

	trace_push(UARTManager, 'manager.emit_removed.ok', {
		cap_id = name,
	})
	return true, nil
end

local function stop_driver(name, rec)
	trace_push(UARTManager, 'driver.stop.begin', {
		cap_id = name,
	})

	local ok_rm, rm_err = emit_removed(name)
	if ok_rm ~= true then
		trace_push(UARTManager, 'driver.stop.emit_removed_failed', {
			cap_id = name,
			err    = tostring(rm_err),
		})
		dlog(UARTManager.logger, 'warn', {
			what   = 'uart_emit_removed_failed',
			cap_id = name,
			err    = tostring(rm_err),
		})
	end

	local ok, err = rec.driver:stop()
	if ok ~= true then
		trace_push(UARTManager, 'driver.stop.failed', {
			cap_id = name,
			err    = tostring(err),
		})
		dlog(UARTManager.logger, 'warn', {
			what   = 'uart_driver_stop_failed',
			cap_id = name,
			err    = tostring(err),
		})
	else
		trace_push(UARTManager, 'driver.stop.ok', {
			cap_id = name,
		})
	end

	UARTManager.drivers[name] = nil
end

local function start_driver(name, spec)
	trace_push(UARTManager, 'driver.start.begin', {
		cap_id = name,
		path   = spec.path,
		baud   = spec.baud,
		mode   = spec.mode,
	})

	local driver_logger = UARTManager.logger
	if driver_logger and driver_logger.child then
		driver_logger = driver_logger:child({ component = 'driver', driver = 'uart', id = name })
	end

	local driver, drv_err = uart_driver.new(UARTManager.scope, name, spec.path, spec, driver_logger)
	if not driver then
		trace_push(UARTManager, 'driver.start.new_failed', {
			cap_id = name,
			err    = tostring(drv_err),
		})
		return nil, tostring(drv_err)
	end

	local init_err = driver:init()
	if init_err ~= '' then
		trace_push(UARTManager, 'driver.start.init_failed', {
			cap_id = name,
			err    = tostring(init_err),
		})
		return nil, tostring(init_err)
	end

	local capabilities, cap_err = driver:capabilities(UARTManager.cap_emit_ch)
	if cap_err ~= '' then
		trace_push(UARTManager, 'driver.start.capabilities_failed', {
			cap_id = name,
			err    = tostring(cap_err),
		})
		return nil, tostring(cap_err)
	end

	local ok, start_err = driver:start()
	if not ok then
		trace_push(UARTManager, 'driver.start.driver_start_failed', {
			cap_id = name,
			err    = tostring(start_err),
		})
		return nil, tostring(start_err)
	end

	local ok_add, add_err = emit_added(name, spec, capabilities)
	if ok_add ~= true then
		trace_push(UARTManager, 'driver.start.emit_added_failed', {
			cap_id = name,
			err    = tostring(add_err),
		})
		local _ = driver:stop()
		return nil, tostring(add_err)
	end

	UARTManager.drivers[name] = {
		driver       = driver,
		spec         = shallow_copy(spec),
		capabilities = capabilities,
	}

	trace_push(UARTManager, 'driver.start.ok', {
		cap_id = name,
	})

	dlog(UARTManager.logger, 'info', {
		what   = 'uart_driver_started',
		cap_id = name,
		path   = spec.path,
	})

	return true, nil
end

---@param logger Logger?
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function UARTManager.start(logger, dev_ev_ch, cap_emit_ch)
	trace_push(UARTManager, 'manager.start.begin', {
		started = UARTManager.started,
	})

	if UARTManager.started then
		trace_push(UARTManager, 'manager.start.already_started')
		return 'Already started'
	end

	local scope, err = fibers.current_scope():child()
	if not scope then
		trace_push(UARTManager, 'manager.start.child_failed', {
			err = tostring(err),
		})
		return 'Failed to create child scope: ' .. tostring(err)
	end

	UARTManager.scope       = scope
	UARTManager.logger      = logger
	UARTManager.dev_ev_ch   = dev_ev_ch
	UARTManager.cap_emit_ch = cap_emit_ch
	UARTManager.started     = true
	UARTManager.drivers     = {}

	scope:finally(function()
		local st, primary = scope:status()

		trace_push(UARTManager, 'manager.scope.finally', {
			status  = st,
			primary = tostring(primary),
		})

		if st == 'failed' then
			dlog(UARTManager.logger, 'error', {
				what   = 'scope_failed',
				err    = tostring(primary),
				status = st,
			})
		end

		dlog(UARTManager.logger, 'debug', { what = 'stopped' })
		reset_runtime_state(scope)
	end)

	trace_push(UARTManager, 'manager.start.ok')

	dlog(UARTManager.logger, 'debug', { what = 'start_called' })
	return ''
end

---@param timeout number?
---@return boolean ok
---@return string error
function UARTManager.stop(timeout)
	trace_push(UARTManager, 'manager.stop.begin', {
		started      = UARTManager.started,
		driver_count = count_drivers(UARTManager.drivers),
	})

	if not UARTManager.started then
		trace_push(UARTManager, 'manager.stop.not_started')
		return false, 'Not started'
	end

	timeout = timeout or STOP_TIMEOUT

	local scope_ref = UARTManager.scope
	if not scope_ref then
		trace_push(UARTManager, 'manager.stop.missing_scope')
		reset_runtime_state(nil)
		return false, 'uart manager missing scope'
	end

	local names = {}
	for name in pairs(UARTManager.drivers) do
		names[#names + 1] = name
	end
	table.sort(names)

	for i = 1, #names do
		local name = names[i]
		local rec = UARTManager.drivers[name]
		if rec then
			stop_driver(name, rec)
		end
	end

	scope_ref:cancel('uart manager stopped')

	local source = fibers.perform(op.named_choice {
		join    = scope_ref:join_op(),
		timeout = sleep.sleep_op(timeout),
	})

	if source == 'timeout' then
		trace_push(UARTManager, 'manager.stop.timeout')
		return false, 'uart manager stop timeout'
	end

	reset_runtime_state(scope_ref)

	trace_push(UARTManager, 'manager.stop.ok')
	return true, ''
end

---@param cfg table
---@return boolean ok
---@return string error
function UARTManager.apply_config(cfg)
	trace_push(UARTManager, 'manager.apply_config.begin', {
		started      = UARTManager.started,
		driver_count = count_drivers(UARTManager.drivers),
	})

	if not UARTManager.started then
		trace_push(UARTManager, 'manager.apply_config.not_started')
		return false, 'uart manager not started'
	end

	local desired, err = normalise_config(cfg)
	if not desired then
		trace_push(UARTManager, 'manager.apply_config.normalise_failed', {
			err = tostring(err),
		})
		return false, tostring(err)
	end

	trace_push(UARTManager, 'manager.apply_config.normalised', {
		desired_count = count_drivers(desired),
	})

	local existing_names = {}
	for name in pairs(UARTManager.drivers) do existing_names[#existing_names + 1] = name end
	table.sort(existing_names)

	for i = 1, #existing_names do
		local name = existing_names[i]
		local rec  = UARTManager.drivers[name]
		local want = desired[name]
		if rec and (not want or not same_spec(rec.spec, want)) then
			trace_push(UARTManager, 'manager.apply_config.stop_mismatch', {
				cap_id = name,
				had    = rec.spec and rec.spec.path or nil,
				want   = want and want.path or nil,
			})
			stop_driver(name, rec)
		end
	end

	local desired_names = {}
	for name in pairs(desired) do desired_names[#desired_names + 1] = name end
	table.sort(desired_names)

	for i = 1, #desired_names do
		local name = desired_names[i]
		local want = desired[name]
		local rec  = UARTManager.drivers[name]
		if not rec then
			local ok, start_err = start_driver(name, want)
			if ok ~= true then
				trace_push(UARTManager, 'manager.apply_config.start_failed', {
					cap_id = name,
					err    = tostring(start_err),
				})
				return false, 'failed to start uart ' .. tostring(name) .. ': ' .. tostring(start_err)
			end
		else
			trace_push(UARTManager, 'manager.apply_config.keep_existing', {
				cap_id = name,
				path   = rec.spec and rec.spec.path or nil,
			})
		end
	end

	trace_push(UARTManager, 'manager.apply_config.ok', {
		driver_count = count_drivers(UARTManager.drivers),
	})

	return true, ''
end

return UARTManager
