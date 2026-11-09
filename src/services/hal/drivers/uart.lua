---@module 'services.hal.drivers.uart'

local fibers    = require 'fibers'
local sleep     = require 'fibers.sleep'
local op        = require 'fibers.op'
local channel   = require 'fibers.channel'
local file      = require 'fibers.io.file'
local exec      = require 'fibers.io.exec'
local uuid      = require 'uuid'

local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local cap_args  = require 'services.hal.types.capability_args'
local resource  = require 'devicecode.support.resource'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local M = {}

local CONTROL_Q_LEN        = 8
local DEFAULT_STOP_TIMEOUT = 5.0

---@class UARTSession
---@field lease_id string
---@field stream Stream
---@field release_lease_now function|nil
---@field release_lease_op function|nil
---@field closed boolean
---@field lease_released boolean
local UARTSession = {}
UARTSession.__index = UARTSession

---@class UARTDriver
---@field id string
---@field path string
---@field default_baud integer|nil
---@field default_mode string|nil
---@field termios_ok boolean
---@field termios_error string|nil
---@field scope Scope|nil
---@field control_ch Channel
---@field emit_ch Channel|nil
---@field logger table|nil
---@field started boolean
---@field caps_applied boolean
---@field active_session UARTSession|nil
---@field active_lease_id string|nil
---@field closing_lease_id string|nil
local Driver = {}
Driver.__index = Driver

local function dlog(self, level, payload)
	if self.logger and self.logger[level] then
		self.logger[level](self.logger, payload)
	end
end

local function finalise_shell_scope(self, shell_scope, status, primary)
	if self.scope ~= shell_scope then
		return
	end

	local session = self.active_session
	if session then
		resource.terminate_checked(
			session,
			primary or status or 'uart shell closed',
			'UART session cleanup failed'
		)
	end

	self.started         = false
	self.scope           = nil
	self.active_session  = nil
	self.active_lease_id = nil
	self.closing_lease_id = nil
end

local function emit_op(emit_ch, class, id, mode, key, data)
	return op.guard(function ()
		local payload, err = hal_types.new.Emit(class, id, mode, key, data)
		if not payload then
			return op.always(false, tostring(err))
		end

		return emit_ch:put_op(payload):wrap(function ()
			return true, nil
		end)
	end)
end

local function status_payload(self)
	return {
		state         = 'available',
		available     = true,
		open          = self.active_session ~= nil or self.closing_lease_id ~= nil,
		lease_id      = self.active_lease_id or self.closing_lease_id,
		path          = self.path,
		baud          = self.default_baud,
		mode          = self.default_mode,
		config_source = 'devicetree',
		termios_ok    = self.termios_ok == true,
		termios_error = self.termios_error,
	}
end

local function meta_payload(self)
	return {
		kind          = 'uart',
		path          = self.path,
		baud          = self.default_baud,
		mode          = self.default_mode,
		config_source = 'devicetree',
		termios = {
			configured = self.termios_ok == true,
			error      = self.termios_error,
		},
	}
end

local function reply_request_op(reply_ch, ok, value_or_err)
	return op.guard(function ()
		local reply, err = hal_types.new.Reply(ok, value_or_err)
		if not reply then
			return op.always(false, 'invalid reply: ' .. tostring(err))
		end

		return reply_ch:put_op(reply):wrap(function (sent, send_err)
			if sent == true then
				return true, nil
			end
			if sent == nil then
				return false, tostring(send_err or 'reply channel closed')
			end
			return false, tostring(send_err or 'reply delivery failed')
		end)
	end)
end

local function release_session_now(driver, lease_id, _reason)
	if driver.active_lease_id ~= lease_id and driver.closing_lease_id ~= lease_id then
		return true, nil
	end

	driver.active_session  = nil
	driver.active_lease_id = nil
	if driver.closing_lease_id == lease_id then
		driver.closing_lease_id = nil
	end
	return true, nil
end

local function session_release_lease_now(session, reason)
	if session.lease_released then
		return true, nil
	end

	session.lease_released = true

	if type(session.release_lease_now) ~= 'function' then
		return true, nil
	end

	return session.release_lease_now(session.lease_id, reason)
end

local function new_session(lease_id, stream, release_lease_now, release_lease_op)
	return setmetatable({
		lease_id          = lease_id,
		stream            = stream,
		release_lease_now = release_lease_now,
		release_lease_op  = release_lease_op,
		closed            = false,
		lease_released    = false,
	}, UARTSession)
end

function UARTSession:read_some_op(max)
	return op.guard(function ()
		if self.closed then
			return op.always(nil, 'uart session closed')
		end
		return self.stream:read_some_op(max)
	end)
end

function UARTSession:read_exactly_op(n)
	return op.guard(function ()
		if self.closed then
			return op.always(nil, 'uart session closed')
		end
		return self.stream:read_exactly_op(n)
	end)
end

function UARTSession:read_line_op(opts)
	return op.guard(function ()
		if self.closed then
			return op.always(nil, 'uart session closed')
		end
		return self.stream:read_line_op(opts)
	end)
end

function UARTSession:read_all_op()
	return op.guard(function ()
		if self.closed then
			return op.always('', 'uart session closed')
		end
		return self.stream:read_all_op()
	end)
end

function UARTSession:write_op(...)
	local parts = { ... }
	return op.guard(function ()
		if self.closed then
			return op.always(nil, 'uart session closed')
		end
		return self.stream:write_op(unpack(parts))
	end)
end

function UARTSession:flush_op()
	return op.guard(function ()
		if self.closed then
			return op.always(nil, 'uart session closed')
		end
		return self.stream:flush_op()
	end)
end

-- Gracefully close the underlying stream and release the active driver lease.
function UARTSession:close_op()
	return fibers.run_scope_op(function ()
		if self.closed then
			return session_release_lease_now(self, 'uart session already closed')
		end

		local stream = self.stream
		local ok, err = fibers.perform(stream:close_op())
		if ok == nil then
			return false, tostring(err)
		end

		self.stream = nil
		self.closed = true

		local ok_release, release_err
		if type(self.release_lease_op) == 'function' then
			ok_release, release_err = fibers.perform(self.release_lease_op(self.lease_id, 'uart session closed'))
		else
			ok_release, release_err = session_release_lease_now(self, 'uart session closed')
		end
		if ok_release ~= true then
			return false, tostring(release_err or 'uart session lease release failed')
		end
		self.lease_released = true

		return true, nil
	end):wrap(function (st, rep, ok, err)
		if st ~= 'ok' then
			return false, tostring(err or rep)
		end
		return ok, err
	end)
end

function UARTSession:terminate(reason)
	local why = reason or 'uart session terminated'
	local first_err

	if self.closed and self.lease_released then
		return true, nil
	end

	self.closed = true

	local stream = self.stream
	self.stream = nil

	local ok_stream, stream_err = resource.terminate(stream, why)
	if ok_stream ~= true and first_err == nil then
		first_err = stream_err or 'uart stream termination failed'
	end

	local ok_release, release_err = session_release_lease_now(self, why)
	if ok_release ~= true and first_err == nil then
		first_err = release_err or 'uart session lease release failed'
	end

	if first_err then
		return nil, first_err
	end

	return true, nil
end


local function mode_stty_args(mode)
	mode = mode or '8N1'
	if mode == '8N1' then
		return { 'cs8', '-cstopb', '-parenb' }
	elseif mode == '7E1' then
		return { 'cs7', '-cstopb', 'parenb', '-parodd' }
	elseif mode == '8O1' then
		return { 'cs8', '-cstopb', 'parenb', 'parodd' }
	end
	return nil, 'unsupported uart mode: ' .. tostring(mode)
end

local function stty_args_for(self)
	local baud = self.default_baud or 115200
	local mode_args, merr = mode_stty_args(self.default_mode)
	if not mode_args then
		return nil, merr
	end

	local args = {
		'stty', '-F', tostring(self.path), tostring(baud),
	}
	for _, a in ipairs(mode_args) do args[#args + 1] = a end
	for _, a in ipairs({
		'-crtscts',
		'-ixon', '-ixoff',
		'-icrnl',
		'-icanon', '-echo', '-isig', '-iexten',
		'-opost', '-onlcr',
		'min', '1', 'time', '0',
		'clocal', 'cread',
	}) do
		args[#args + 1] = a
	end
	return args, nil
end

local function configure_termios_op(self, why)
	return fibers.run_scope_op(function ()
		local args, aerr = stty_args_for(self)
		if not args then
			self.termios_ok = false
			self.termios_error = tostring(aerr)
			return false, self.termios_error
		end

		local spec = { stdin = 'null', stdout = 'pipe', stderr = 'stdout' }
		for i = 1, #args do spec[i] = args[i] end
		local cmd = exec.command(spec)
		local output, status, code, sig, err = fibers.perform(cmd:combined_output_op())
		if status == 'exited' and code == 0 then
			self.termios_ok = true
			self.termios_error = nil
			dlog(self, 'debug', {
				what = 'uart_termios_configured',
				why  = why,
				path = self.path,
				baud = self.default_baud or 115200,
				mode = self.default_mode or '8N1',
			})
			return true, nil
		end

		local detail = tostring(err or output or ('status=' .. tostring(status)))
		if status == 'exited' then
			detail = detail .. ' (exit ' .. tostring(code) .. ')'
		elseif status == 'signalled' then
			detail = detail .. ' (signal ' .. tostring(sig) .. ')'
		end
		self.termios_ok = false
		self.termios_error = detail
		return false, 'uart termios stty failed for ' .. tostring(self.path) .. ': ' .. detail
	end):wrap(function (st, rep, ok, err)
		if st ~= 'ok' then
			self.termios_ok = false
			self.termios_error = tostring(err or rep)
			return false, self.termios_error
		end
		return ok, err
	end)
end

local function open_stream_op(path)
	return fibers.run_scope_op(function ()
		-- Box the currently synchronous file.open(...) impurity inside one
		-- operation-owned subtree. Surface remains op-native.
		local stream, err = file.open(path, 'r+')
		if not stream then
			return false, tostring(err)
		end
		return true, stream
	end):wrap(function (st, rep, ok, value_or_err)
		if st ~= 'ok' then
			return false, tostring(value_or_err or rep)
		end
		return ok, value_or_err
	end)
end

local release_session_gracefully_op

local function open_session_op(self)
	return fibers.run_scope_op(function (scope)
		local ok_cfg, cfg_err = fibers.perform(configure_termios_op(self, 'open'))
		if ok_cfg ~= true then
			return false, tostring(cfg_err)
		end

		local ok, stream_or_err = fibers.perform(open_stream_op(self.path))
		if not ok then
			return false, stream_or_err
		end

		local stream = stream_or_err
		local handed_off = false
		scope:finally(function (_, status, primary)
			if not handed_off then
				resource.terminate_checked(stream, primary or status or 'uart open failed', 'uart open stream cleanup failed')
			end
		end)

		local lease_id = uuid.new()
		local session = new_session(
			lease_id,
			stream,
			function (active_lease_id, reason)
				return release_session_now(self, active_lease_id, reason)
			end,
			function (active_lease_id, _reason)
				return release_session_gracefully_op(self, active_lease_id, true)
			end
		)

		local reply, rerr = hal_types.new.UARTOpenReply(
			lease_id,
			session,
			self.path,
			self.default_baud,
			self.default_mode
		)
		if not reply then
			return false, tostring(rerr)
		end

		handed_off = true
		return true, reply
	end):wrap(function (st, rep, ok, value_or_err)
		if st ~= 'ok' then
			return false, tostring(value_or_err or rep)
		end
		return ok, value_or_err
	end)
end

local function publish_status_op(self)
	return emit_op(self.emit_ch, 'uart', self.id, 'state', 'status', status_payload(self))
end

local function publish_event_op(self, event_name, data)
	return emit_op(self.emit_ch, 'uart', self.id, 'event', event_name, data)
end

function release_session_gracefully_op(self, lease_id, emit_closed_event)
	return fibers.run_scope_op(function ()
		if self.active_lease_id ~= lease_id then
			return true, nil
		end

		self.active_session  = nil
		self.active_lease_id = nil
		if self.closing_lease_id == lease_id then
			self.closing_lease_id = nil
		end

		local ok_status, status_err = fibers.perform(publish_status_op(self))
		if not ok_status then
			return false, tostring(status_err)
		end

		if emit_closed_event then
			local ok_event, event_err = fibers.perform(publish_event_op(self, 'closed', {
				lease_id = lease_id,
				path     = self.path,
			}))
			if not ok_event then
				return false, tostring(event_err)
			end
		end

		return true, nil
	end):wrap(function (st, rep, ok, err)
		if st ~= 'ok' then
			return false, tostring(err or rep)
		end
		return ok, err
	end)
end

local function methods_for(self)
	return {
		status = function (_opts, _request)
			return op.always(true, status_payload(self))
		end,

		open = function (opts, _request)
			if opts ~= nil and (type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.UARTOpenOpts) then
				return op.always(false, 'invalid open opts')
			end

			if self.active_session ~= nil or self.closing_lease_id ~= nil then
				return op.always(false, 'busy')
			end

			return fibers.run_scope_op(function (scope)
				local ok, reply_or_err = fibers.perform(open_session_op(self))
				if not ok then
					return false, reply_or_err
				end

				local reply = reply_or_err
				local handed_off = false

				scope:finally(function ()
					if not handed_off and self.active_session == reply.session then
						resource.terminate_checked(reply.session, 'uart open abandoned', 'UART open session cleanup failed')
						self.active_session  = nil
						self.active_lease_id = nil
						if self.closing_lease_id == reply.lease_id then
							self.closing_lease_id = nil
						end
					end
				end)

				self.active_session  = reply.session
				self.active_lease_id = reply.lease_id

				local ok_status, status_err = fibers.perform(publish_status_op(self))
				if not ok_status then
					return false, tostring(status_err)
				end

				local ok_event, event_err = fibers.perform(publish_event_op(self, 'opened', {
					lease_id = reply.lease_id,
					path     = self.path,
				}))
				if not ok_event then
					return false, tostring(event_err)
				end

				handed_off = true
				return true, reply
			end):wrap(function (st, rep, ok, value_or_err)
				if st ~= 'ok' then
					return false, tostring(value_or_err or rep)
				end
				return ok, value_or_err
			end)
		end,
	}
end

local function handle_request_op(self, request)
	return fibers.run_scope_op(function ()
		local methods = methods_for(self)
		local fn = methods[request.verb]

		local ok, value_or_err
		if type(fn) ~= 'function' then
			ok = false
			value_or_err = 'unsupported verb: ' .. tostring(request.verb)
		else
			ok, value_or_err = fibers.perform(fn(request.opts, request))
		end

		local replied, reply_err =
			fibers.perform(reply_request_op(request.reply_ch, ok, value_or_err))

		if not replied then
			return false, tostring(reply_err)
		end

		return true, nil
	end):wrap(function (st, rep, ok, err)
		if st ~= 'ok' then
			return false, tostring(err or rep)
		end
		return ok, err
	end)
end

local function shell_main(self)
	local shell_scope = assert(self.scope, 'uart shell without scope')
	assert(self.emit_ch, 'uart shell without emit channel')

	shell_scope:finally(function (_, status, primary)
		finalise_shell_scope(self, shell_scope, status, primary)
	end)

	local ok_meta, meta_err =
		fibers.perform(emit_op(self.emit_ch, 'uart', self.id, 'meta', 'details', meta_payload(self)))
	if ok_meta ~= true then
		error(tostring(meta_err or 'initial uart meta emit failed'), 0)
	end

	local ok_status, status_err = fibers.perform(publish_status_op(self))
	if ok_status ~= true then
		error(tostring(status_err or 'initial uart status emit failed'), 0)
	end

	while true do
		local request = fibers.perform(self.control_ch:get_op())
		if not request then
			return
		end

		local ok_req, req_err = fibers.perform(handle_request_op(self, request))
		if not ok_req then
			dlog(self, 'warn', {
				what = 'uart_request_failed',
				err  = tostring(req_err),
			})
		end
	end
end

function Driver:capabilities_op(emit_ch)
	return op.guard(function ()
		if self.caps_applied then
			return op.always(false, 'capabilities already applied')
		end

		self.emit_ch = emit_ch

		local cap, err = cap_types.new.UARTCapability(self.id, self.control_ch)
		if not cap then
			return op.always(false, tostring(err))
		end

		self.caps_applied = true
		return op.always(true, { cap })
	end)
end

---@param owner_scope Scope
function Driver:start_op(owner_scope)
	assert(owner_scope ~= nil, 'uart driver start_op: owner_scope is required')

	return fibers.run_scope_op(function ()
		if self.started then
			return false, 'already started'
		end
		if not self.caps_applied then
			return false, 'capabilities not applied'
		end
		if not self.emit_ch then
			return false, 'missing emit channel'
		end

		local ok_cfg, cfg_err = fibers.perform(configure_termios_op(self, 'start'))
		if ok_cfg ~= true then
			return false, tostring(cfg_err)
		end

		local shell_scope, serr = owner_scope:child()
		if not shell_scope then
			return false, tostring(serr)
		end

		self.scope = shell_scope

		local ok, err = shell_scope:spawn(function ()
			return shell_main(self)
		end)
		if not ok then
			self.scope = nil
			shell_scope:cancel(tostring(err or 'uart shell spawn failed'))
			return false, tostring(err)
		end

		self.started = true
		return true, nil
	end):wrap(function (st, rep, ok, err)
		if st ~= 'ok' then
			return false, tostring(err or rep)
		end
		return ok, err
	end)
end

function Driver:terminate(reason)
	if self.scope then
		self.scope:cancel(reason or 'uart driver terminated')
	end
	if self.active_session then
		self.active_session:terminate(reason or 'uart driver terminated')
	end
	self.started = false
	self.scope = nil
	self.active_session = nil
	self.active_lease_id = nil
	self.closing_lease_id = nil
	return true, nil
end

function Driver:shutdown_op(timeout)
	timeout = timeout or DEFAULT_STOP_TIMEOUT

	return op.guard(function ()
		if not self.started or not self.scope then
			return op.always(true, nil)
		end

		local shell_scope = self.scope
		local session = self.active_session

		shell_scope:cancel()

		return fibers.boolean_choice(
			shell_scope:join_op():wrap(function ()
				-- Make the post-stop contract explicit: any previously returned
				-- session wrapper is no longer usable, even if the shell stop
				-- path did not get to mark it in time.
				if session then
					session.closed = true
				end

				finalise_shell_scope(self, shell_scope, 'ok', nil)
				return true, nil
			end),
			sleep.sleep_op(timeout):wrap(function ()
				return false, 'uart driver stop timeout'
			end)
		):wrap(function (completed, _a, b)
			if completed then
				return true, nil
			end
			return false, b
		end)
	end)
end

function Driver:fault_op()
	if self.scope and self.started then
		return self.scope:fault_op()
	end
	return op.never()
end

---@param id string
---@param path string
---@param baud integer|nil
---@param mode string|nil
---@param logger table|nil
---@return UARTDriver
function M.new(id, path, baud, mode, logger)
	assert(type(id) == 'string' and id ~= '', 'uart.new: invalid id')
	assert(type(path) == 'string' and path ~= '', 'uart.new: invalid path')

	return setmetatable({
		id              = id,
		path            = path,
		default_baud    = baud,
		default_mode    = mode,
		scope           = nil,
		control_ch      = channel.new(CONTROL_Q_LEN),
		emit_ch         = nil,
		logger          = logger,
		termios_ok      = false,
		termios_error   = nil,
		started         = false,
		caps_applied    = false,
		active_session  = nil,
		active_lease_id = nil,
		closing_lease_id = nil,
	}, Driver)
end

M.Driver = Driver
M.UARTSession = UARTSession
return M
