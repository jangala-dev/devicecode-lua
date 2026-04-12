-- services/hal/drivers/uart.lua
--
-- UART HAL driver.
--
-- Native dev-branch behaviour:
--   * exposes a uart capability with control verb 'open'
--   * returns a real fibers Stream in Reply.reason
--   * the caller uses that stream directly in-process
--
-- The legacy bus-level byte relay is deliberately not used here.

local fibers  = require 'fibers'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local file    = require 'fibers.io.file'
local exec    = require 'fibers.io.exec'
local channel = require 'fibers.channel'

local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local cap_args  = require 'services.hal.types.capability_args'

local perform = fibers.perform
local unpack  = rawget(table, 'unpack') or _G.unpack

local CONTROL_Q_LEN        = 8
local DEFAULT_STOP_TIMEOUT = 5.0
local TRACE_MAX            = 128

local function dlog(logger, level, payload)
	if logger and logger[level] then
		logger[level](logger, payload)
	end
end

local function trace_push(self, what, fields)
	self._trace_seq = (self._trace_seq or 0) + 1

	local rec = {
		seq    = self._trace_seq,
		t      = fibers.now(),
		what   = what,
		cap_id = self.cap_id,
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

---@class UARTDriver
---@field cap_id string
---@field device_path string
---@field baud integer|nil
---@field mode string|nil
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel|nil
---@field logger Logger|nil
---@field initialised boolean
---@field active_stream Stream|nil
---@field _trace table[]
---@field _trace_seq integer
local UARTDriver = {}
UARTDriver.__index = UARTDriver

local function emit_state(emit_ch, cap_id, payload, logger)
	if not emit_ch then return end
	local msg, err = hal_types.new.Emit('uart', cap_id, 'state', 'stream', payload)
	if not msg then
		dlog(logger, 'warn', { what = 'uart_emit_failed', err = tostring(err), cap_id = cap_id })
		return
	end
	emit_ch:put(msg)
end

local function emit_event(emit_ch, cap_id, key, payload, logger)
	if not emit_ch then return end
	local msg, err = hal_types.new.Emit('uart', cap_id, 'event', key, payload)
	if not msg then
		dlog(logger, 'warn', { what = 'uart_emit_failed', err = tostring(err), cap_id = cap_id, key = key })
		return
	end
	emit_ch:put(msg)
end

local function parse_mode(mode)
	mode = mode or '8N1'
	local db, par, sb = tostring(mode):match('^(%d)([NEO])(%d)$')
	if not db then
		return nil, 'unsupported serial mode: ' .. tostring(mode)
	end

	db = tonumber(db)
	sb = tonumber(sb)

	local parity
	if par == 'N' then
		parity = 'none'
	elseif par == 'E' then
		parity = 'even'
	elseif par == 'O' then
		parity = 'odd'
	else
		return nil, 'unsupported parity in mode: ' .. tostring(mode)
	end

	return {
		data_bits = db,
		stop_bits = sb,
		parity    = parity,
	}, nil
end

local function stty_argv(device_path, baud, mode)
	local argv = { 'stty', '-F', tostring(device_path), 'raw', '-echo' }

	if baud ~= nil then
		argv[#argv + 1] = tostring(baud)
	end

	local pmode, err = parse_mode(mode or '8N1')
	if not pmode then
		return nil, err
	end

	argv[#argv + 1] = 'cs' .. tostring(pmode.data_bits)

	if pmode.stop_bits == 2 then
		argv[#argv + 1] = 'cstopb'
	else
		argv[#argv + 1] = '-cstopb'
	end

	if pmode.parity == 'none' then
		argv[#argv + 1] = '-parenb'
		argv[#argv + 1] = '-parodd'
	elseif pmode.parity == 'even' then
		argv[#argv + 1] = 'parenb'
		argv[#argv + 1] = '-parodd'
	elseif pmode.parity == 'odd' then
		argv[#argv + 1] = 'parenb'
		argv[#argv + 1] = 'parodd'
	end

	return argv, nil
end

local function configure_port(device_path, baud, mode)
	local argv, err = stty_argv(device_path, baud, mode)
	if not argv then return nil, err end

	local cmd = exec.command(unpack(argv))
	local out, st, code, sig, cerr = perform(cmd:combined_output_op())
	if st == 'exited' and code == 0 then
		return true, nil
	end

	local detail = cerr or out or ('status=' .. tostring(st))
	if st == 'exited' then
		detail = tostring(detail) .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then
		detail = tostring(detail) .. ' (signal ' .. tostring(sig) .. ')'
	end
	return nil, detail
end

local function open_mode_from_opts(opts)
	if opts.read and opts.write then return 'r+' end
	if opts.read then return 'r' end
	return 'w'
end

local function unregister_stream(self, stream)
	if self.active_stream ~= stream then return end

	trace_push(self, 'driver.stream.unregister', {
		path = self.device_path,
	})

	self.active_stream = nil
	emit_state(self.cap_emit_ch, self.cap_id, {
		open = false,
		path = self.device_path,
		baud = self.baud,
		mode = self.mode,
	}, self.logger)
	emit_event(self.cap_emit_ch, self.cap_id, 'closed', {
		path = self.device_path,
	}, self.logger)
end

local function wrap_stream_close(self, stream)
	if stream._devicecode_uart_wrapped then
		return stream
	end
	stream._devicecode_uart_wrapped = true

	local old_close_op = assert(stream.close_op, 'uart stream missing close_op()')

	stream.close_op = function(s)
		return op.guard(function()
			return old_close_op(s):wrap(function(ok, err)
				trace_push(self, 'driver.stream.close_op.done', {
					ok  = (ok ~= nil),
					err = (ok == nil) and tostring(err) or nil,
				})

				if ok ~= nil then
					unregister_stream(self, s)
				end
				return ok, err
			end)
		end)
	end

	return stream
end

---@param parent_scope Scope
---@param cap_id string
---@param device_path string
---@param opts table|nil
---@param logger Logger|nil
---@return UARTDriver?|nil
---@return string error
local function new(parent_scope, cap_id, device_path, opts, logger)
	opts = opts or {}

	if type(cap_id) ~= 'string' or cap_id == '' then
		return nil, 'invalid capability id'
	end
	if type(device_path) ~= 'string' or device_path == '' then
		return nil, 'invalid device path'
	end

	local scope, err = parent_scope:child()
	if not scope then
		return nil, 'failed to create UART driver scope: ' .. tostring(err)
	end

	local self = setmetatable({
		cap_id        = cap_id,
		device_path   = device_path,
		baud          = (type(opts.baud) == 'number') and math.floor(opts.baud) or nil,
		mode          = (type(opts.mode) == 'string' and opts.mode ~= '') and opts.mode or nil,
		scope         = scope,
		control_ch    = channel.new(CONTROL_Q_LEN),
		cap_emit_ch   = nil,
		logger        = logger,
		initialised   = false,
		active_stream = nil,
		_trace        = {},
		_trace_seq    = 0,
	}, UARTDriver)

	trace_push(self, 'driver.new', {
		path = device_path,
		baud = self.baud,
		mode = self.mode,
	})

	return self, ''
end

function UARTDriver:debug_snapshot()
	return {
		cap_id        = self.cap_id,
		device_path   = self.device_path,
		baud          = self.baud,
		mode          = self.mode,
		initialised   = self.initialised,
		active_stream = self.active_stream ~= nil,
		trace         = copy_trace(self._trace),
	}
end

function UARTDriver:init()
	trace_push(self, 'driver.init.begin', {
		initialised = self.initialised,
	})

	if self.initialised then
		trace_push(self, 'driver.init.already_initialised')
		return 'already initialised'
	end

	self.initialised = true
	trace_push(self, 'driver.init.ok')
	return ''
end

---@param emit_ch Channel
---@return Capability[]?
---@return string error
function UARTDriver:capabilities(emit_ch)
	trace_push(self, 'driver.capabilities.begin', {
		initialised = self.initialised,
	})

	if not self.initialised then
		trace_push(self, 'driver.capabilities.not_initialised')
		return nil, 'uart driver not initialised'
	end

	self.cap_emit_ch = emit_ch
	local cap, err = cap_types.new.UARTCapability(self.cap_id, self.control_ch)
	if not cap then
		trace_push(self, 'driver.capabilities.failed', {
			err = tostring(err),
		})
		return nil, tostring(err)
	end

	trace_push(self, 'driver.capabilities.ok')
	return { cap }, ''
end

---@param opts UARTOpenOpts?
---@return boolean ok
---@return any value_or_err
function UARTDriver:open(opts)
	trace_push(self, 'driver.open.begin', {
		active_stream = self.active_stream ~= nil,
		read          = opts and opts.read or nil,
		write         = opts and opts.write or nil,
	})

	if opts == nil or getmetatable(opts) ~= cap_args.UARTOpenOpts then
		trace_push(self, 'driver.open.invalid_opts')
		return false, 'invalid options'
	end

	if self.active_stream ~= nil then
		trace_push(self, 'driver.open.already_open')
		return false, 'uart already open'
	end

	local ok_cfg, cfg_err = configure_port(self.device_path, self.baud, self.mode)
	if ok_cfg ~= true then
		trace_push(self, 'driver.open.configure_failed', {
			err = tostring(cfg_err),
		})
		dlog(self.logger, 'warn', {
			what   = 'uart_configure_failed',
			cap_id = self.cap_id,
			path   = self.device_path,
			err    = tostring(cfg_err),
		})
		return false, 'stty failed: ' .. tostring(cfg_err)
	end

	local stream, open_err = file.open(self.device_path, open_mode_from_opts(opts))
	if not stream then
		trace_push(self, 'driver.open.file_open_failed', {
			err = tostring(open_err),
		})
		return false, 'open failed: ' .. tostring(open_err)
	end

	pcall(function()
		if stream.setvbuf then stream:setvbuf('no') end
	end)

	stream = wrap_stream_close(self, stream)
	self.active_stream = stream

	trace_push(self, 'driver.open.ok', {
		path = self.device_path,
	})

	emit_state(self.cap_emit_ch, self.cap_id, {
		open = true,
		path = self.device_path,
		baud = self.baud,
		mode = self.mode,
	}, self.logger)
	emit_event(self.cap_emit_ch, self.cap_id, 'opened', {
		path = self.device_path,
		baud = self.baud,
		mode = self.mode,
	}, self.logger)

	return true, stream
end

---@param _opts any
---@return boolean ok
---@return any value_or_err
function UARTDriver:close(_opts)
	trace_push(self, 'driver.close.begin', {
		active_stream = self.active_stream ~= nil,
	})

	local s = self.active_stream
	if not s then
		trace_push(self, 'driver.close.noop')
		return true, nil
	end

	local ok, err = perform(s:close_op())
	if ok == nil then
		trace_push(self, 'driver.close.failed', {
			err = tostring(err),
		})
		return false, err
	end

	trace_push(self, 'driver.close.ok')
	return true, nil
end

---@param opts UARTWriteOpts?
---@return boolean ok
---@return any value_or_err
function UARTDriver:write(opts)
	trace_push(self, 'driver.write.begin', {
		active_stream = self.active_stream ~= nil,
		n             = opts and opts.data and #opts.data or nil,
	})

	if opts == nil or getmetatable(opts) ~= cap_args.UARTWriteOpts then
		trace_push(self, 'driver.write.invalid_opts')
		return false, 'invalid options'
	end

	local s = self.active_stream
	if not s then
		trace_push(self, 'driver.write.not_open')
		return false, 'uart is not open'
	end

	local n, err = perform(s:write_op(opts.data))
	if n == nil then
		trace_push(self, 'driver.write.failed', {
			err = tostring(err),
		})
		return false, err
	end

	trace_push(self, 'driver.write.ok', {
		n = n,
	})
	return true, n
end

function UARTDriver:control_manager()
	trace_push(self, 'driver.control_manager.enter')

	fibers.current_scope():finally(function()
		trace_push(self, 'driver.control_manager.exit')
		dlog(self.logger, 'debug', { what = 'control_manager_exiting', cap_id = self.cap_id })
	end)

	while true do
		local request, req_err = self.control_ch:get()
		if not request then
			trace_push(self, 'driver.control_manager.channel_closed', {
				err = tostring(req_err),
			})
			dlog(self.logger, 'debug', {
				what   = 'control_ch_closed',
				cap_id = self.cap_id,
				err    = tostring(req_err),
			})
			break
		end

		trace_push(self, 'driver.control_manager.request', {
			verb = request.verb,
		})

		local fn = self[request.verb]
		local ok, value_or_err
		if type(fn) ~= 'function' then
			ok, value_or_err = false, 'unsupported verb: ' .. tostring(request.verb)
		else
			local st, _, r1, r2 = fibers.run_scope(function()
				return fn(self, request.opts)
			end)
			if st ~= 'ok' then
				ok, value_or_err = false, 'internal error: ' .. tostring(r1)
			else
				ok, value_or_err = r1, r2
			end
		end

		trace_push(self, 'driver.control_manager.reply', {
			verb     = request.verb,
			ok       = (ok == true),
			err      = (ok ~= true) and tostring(value_or_err) or nil,
			has_value = (ok == true and value_or_err ~= nil) or false,
		})

		local reply = hal_types.new.Reply(ok, value_or_err)
		if reply then
			request.reply_ch:put(reply)
		end
	end
end

---@return boolean ok
---@return string error
function UARTDriver:start()
	trace_push(self, 'driver.start.begin', {
		initialised = self.initialised,
	})

	if not self.initialised then
		trace_push(self, 'driver.start.not_initialised')
		return false, 'uart driver not initialised'
	end

	self.scope:finally(function()
		trace_push(self, 'driver.scope.finally.begin', {
			active_stream = self.active_stream ~= nil,
		})

		if self.active_stream then
			pcall(function()
				perform(self.active_stream:close_op())
			end)
			self.active_stream = nil
		end

		trace_push(self, 'driver.scope.finally.end')
	end)

	self.scope:spawn(function() self:control_manager() end)

	emit_state(self.cap_emit_ch, self.cap_id, {
		open = false,
		path = self.device_path,
		baud = self.baud,
		mode = self.mode,
	}, self.logger)

	trace_push(self, 'driver.start.ok')
	return true, ''
end

---@param timeout number?
---@return boolean ok
---@return string error
function UARTDriver:stop(timeout)
	timeout = timeout or DEFAULT_STOP_TIMEOUT

	trace_push(self, 'driver.stop.begin', {
		timeout       = timeout,
		active_stream = self.active_stream ~= nil,
	})

	if self.active_stream then
		pcall(function()
			perform(self.active_stream:close_op())
		end)
		self.active_stream = nil
	end

	if self.control_ch and type(self.control_ch.close) == 'function' then
		trace_push(self, 'driver.stop.control_close.begin')
		pcall(function()
			self.control_ch:close('uart driver stopped')
		end)
		trace_push(self, 'driver.stop.control_close.end')
	else
		trace_push(self, 'driver.stop.control_close.unsupported')
	end

	self.scope:cancel('uart driver stopped')

	local source = perform(op.named_choice {
		join    = self.scope:join_op(),
		timeout = sleep.sleep_op(timeout),
	})

	if source == 'timeout' then
		trace_push(self, 'driver.stop.timeout')
		return false, 'uart driver stop timeout'
	end

	trace_push(self, 'driver.stop.ok')
	return true, ''
end

return {
	new        = new,
	UARTDriver = UARTDriver,
}
