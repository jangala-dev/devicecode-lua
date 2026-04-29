---@module 'services.hal.drivers.signature_verify_provider'

local fibers       = require 'fibers'
local sleep        = require 'fibers.sleep'
local op           = require 'fibers.op'
local channel      = require 'fibers.channel'

local hal_types    = require 'services.hal.types.core'
local cap_types    = require 'services.hal.types.capabilities'
local cap_args     = require 'services.hal.types.capability_args'
local control_loop = require 'services.hal.support.control_loop'

local backend_mod  = require 'services.hal.drivers.signature_verify_openssl'

local M = {}

local CONTROL_Q_LEN        = 8
local DONE_Q_LEN           = 32
local DEFAULT_STOP_TIMEOUT = 5.0
local DEFAULT_MAX_IN_FLIGHT = 4

---@class SignatureVerifyDone
---@field reply_ch Channel
---@field ok boolean
---@field value_or_err any

---@class SignatureVerifyProvider
---@field id string
---@field opts table
---@field logger table|nil
---@field scope Scope|nil
---@field control_ch Channel
---@field done_ch Channel
---@field emit_ch Channel|nil
---@field backend SignatureVerifyOpenSSL
---@field started boolean
---@field caps_applied boolean
---@field in_flight integer
---@field max_in_flight integer
local Driver = {}
Driver.__index = Driver

local function deep_copy(v, seen)
	if type(v) ~= 'table' then
		return v
	end

	seen = seen or {}
	if seen[v] then
		return seen[v]
	end

	local out = {}
	seen[v] = out
	for k, x in pairs(v) do
		out[deep_copy(k, seen)] = deep_copy(x, seen)
	end
	return out
end

local function dlog(self, level, payload)
	if self.logger and self.logger[level] then
		self.logger[level](self.logger, payload)
	end
end

local function normalise_max_in_flight(v)
	if v == nil then
		return DEFAULT_MAX_IN_FLIGHT
	end

	if type(v) ~= 'number' then
		error('signature_verify_provider.new: max_in_flight must be a number', 2)
	end

	if v ~= v or v == math.huge or v == -math.huge then
		error('signature_verify_provider.new: max_in_flight must be finite', 2)
	end

	if v % 1 ~= 0 then
		error('signature_verify_provider.new: max_in_flight must be an integer', 2)
	end

	if v < 1 then
		error('signature_verify_provider.new: max_in_flight must be >= 1', 2)
	end

	return v
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

local function reply_now(self, reply_ch, ok, value_or_err)
	local sent, err = fibers.perform(control_loop.reply_op(reply_ch, ok, value_or_err))
	if not sent then
		dlog(self, 'warn', {
			what = 'signature_verify_reply_failed',
			err  = tostring(err),
		})
	end
end

local function validate_verify_opts(opts)
	if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.SignatureVerifyEd25519Opts then
		return false, 'invalid verify_ed25519 opts'
	end
	return true, nil
end

local function spawn_verify_worker(self, request)
	local ok_opts, opts_err = validate_verify_opts(request.opts)
	if not ok_opts then
		reply_now(self, request.reply_ch, false, opts_err)
		return
	end

	if self.in_flight >= self.max_in_flight then
		reply_now(self, request.reply_ch, false, 'busy')
		return
	end

	local scope = assert(self.scope, 'signature_verify worker spawn without scope')
	local opts  = request.opts

	self.in_flight = self.in_flight + 1

	local ok, err = scope:spawn(function ()
		local vok, verr = fibers.perform(self.backend:verify_ed25519_op(
			opts.pubkey_pem,
			opts.message,
			opts.signature
		))

		fibers.perform(self.done_ch:put_op({
			reply_ch      = request.reply_ch,
			ok            = vok,
			value_or_err  = verr,
		}))
	end)

	if not ok then
		self.in_flight = self.in_flight - 1
		reply_now(self, request.reply_ch, false, tostring(err))
	end
end

local function handle_request(self, request)
	if not request then
		return false
	end

	if request.verb == 'verify_ed25519' then
		spawn_verify_worker(self, request)
		return true
	end

	reply_now(self, request.reply_ch, false, 'unsupported verb: ' .. tostring(request.verb))
	return true
end

local function handle_done(self, done)
	if not done then
		return false
	end

	if self.in_flight > 0 then
		self.in_flight = self.in_flight - 1
	end

	reply_now(self, done.reply_ch, done.ok, done.value_or_err)
	return true
end

local function shell_main(self)
	assert(self.scope,   'signature_verify shell without scope')
	assert(self.emit_ch, 'signature_verify shell without emit channel')

	local meta_ok, meta_err = fibers.perform(emit_op(
		self.emit_ch,
		'signature_verify',
		self.id,
		'meta',
		'info',
		{
			provider      = 'hal.signature_verify',
			backend       = self.backend.backend_name or 'openssl-cli',
			version       = 2,
			max_in_flight = self.max_in_flight,
		}
	))
	if meta_ok ~= true then
		error(tostring(meta_err or 'initial meta emit failed'), 0)
	end

	local st_ok, st_err = fibers.perform(emit_op(
		self.emit_ch,
		'signature_verify',
		self.id,
		'state',
		'status',
		{ state = 'available' }
	))
	if st_ok ~= true then
		error(tostring(st_err or 'initial state emit failed'), 0)
	end

	local scope = assert(self.scope, 'signature_verify shell without scope')

	while true do
		local which, a, b = fibers.perform(fibers.named_choice{
			req  = self.control_ch:get_op(),
			done = self.done_ch:get_op(),
			stop = scope:not_ok_op(),
		})

		if which == 'stop' then
			local status, reason_or_primary = a, b
			dlog(self, 'debug', {
				what      = 'signature_verify_shell_stopping',
				status    = tostring(status),
				reason    = tostring(reason_or_primary),
				in_flight = self.in_flight,
			})
			return
		end

		if which == 'done' then
			local done = a
			if not done then
				return
			end
			handle_done(self, done)
		elseif which == 'req' then
			local request = a
			if not request then
				return
			end
			handle_request(self, request)
		end
	end
end

function Driver:capabilities_op(emit_ch)
	return op.guard(function ()
		if self.caps_applied then
			return op.always(false, 'capabilities already applied')
		end

		self.emit_ch = emit_ch

		local cap, err = cap_types.new.SignatureVerifyCapability(self.id, self.control_ch)
		if not cap then
			return op.always(false, tostring(err))
		end

		self.caps_applied = true
		return op.always(true, { cap })
	end)
end

---@param owner_scope Scope
function Driver:start_op(owner_scope)
	assert(owner_scope ~= nil, 'signature_verify provider start_op: owner_scope is required')

	return op.guard(function ()
		if self.started then
			return op.always(false, 'already started')
		end
		if not self.caps_applied then
			return op.always(false, 'capabilities not applied')
		end
		if not self.emit_ch then
			return op.always(false, 'missing emit channel')
		end

		local shell_scope, err = owner_scope:child()
		if not shell_scope then
			return op.always(false, tostring(err))
		end

		self.scope = shell_scope

		local ok, serr = shell_scope:spawn(function ()
			return shell_main(self)
		end)
		if not ok then
			self.scope = nil
			return op.always(false, tostring(serr))
		end

		self.started = true
		return op.always(true, nil)
	end)
end

function Driver:stop_op(timeout)
	timeout = timeout or DEFAULT_STOP_TIMEOUT

	return op.guard(function ()
		if not self.started or not self.scope then
			return op.always(true, nil)
		end

		local shell_scope = self.scope
		shell_scope:cancel('signature_verify provider stopped')

		return fibers.boolean_choice(
			shell_scope:join_op():wrap(function ()
				self.started   = false
				self.scope     = nil
				self.in_flight = 0
				return true, nil
			end),
			sleep.sleep_op(timeout):wrap(function ()
				return false, 'signature_verify provider stop timeout'
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
---@param opts table|nil
---@param logger table|nil
---@return SignatureVerifyProvider
function M.new(id, opts, logger)
	assert(type(id) == 'string' and id ~= '', 'signature_verify_provider.new: invalid id')

	local raw_opts = opts or {}
	local injected_backend = raw_opts.backend

	opts = deep_copy(raw_opts)

	local max_in_flight = normalise_max_in_flight(opts.max_in_flight)

	return setmetatable({
		id            = id,
		opts          = opts,
		logger        = logger,
		scope         = nil,
		control_ch    = channel.new(CONTROL_Q_LEN),
		done_ch       = channel.new(DONE_Q_LEN),
		emit_ch       = nil,
		backend       = injected_backend or backend_mod.new(opts),
		started       = false,
		caps_applied  = false,
		in_flight     = 0,
		max_in_flight = max_in_flight,
	}, Driver)
end

M.Driver = Driver
return M
