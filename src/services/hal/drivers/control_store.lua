---@module 'services.hal.drivers.control_store'

local fibers       = require 'fibers'
local sleep        = require 'fibers.sleep'
local op           = require 'fibers.op'
local channel      = require 'fibers.channel'

local hal_types    = require 'services.hal.types.core'
local cap_types    = require 'services.hal.types.capabilities'
local cap_args     = require 'services.hal.types.capability_args'
local control_loop = require 'services.hal.support.control_loop'

local provider_mod = require 'services.hal.drivers.control_store_provider'

local M = {}

local CONTROL_Q_LEN        = 8
local DEFAULT_STOP_TIMEOUT = 5.0

---@class ControlStoreDriver
---@field id string
---@field root string
---@field scope Scope|nil
---@field control_ch Channel
---@field emit_ch Channel|nil
---@field logger table|nil
---@field provider ControlStoreProvider
---@field started boolean
---@field caps_applied boolean
local Driver = {}
Driver.__index = Driver


local function finalise_shell_scope(self, shell_scope)
	if self.scope ~= shell_scope then
		return
	end
	self.started = false
	self.scope = nil
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

local function methods_for(self)
	return {
		status = function (opts, request)
			return self.provider:status_op()
		end,

		get = function (opts, request)
			if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ControlStoreGetOpts then
				return op.always(false, 'invalid get opts')
			end
			return self.provider:get_op(opts)
		end,

		put = function (opts, request)
			if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ControlStorePutOpts then
				return op.always(false, 'invalid put opts')
			end
			return self.provider:put_op(opts)
		end,

		delete = function (opts, request)
			if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ControlStoreDeleteOpts then
				return op.always(false, 'invalid delete opts')
			end
			return self.provider:delete_op(opts)
		end,

		list = function (opts, request)
			if opts ~= nil and (type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ControlStoreListOpts) then
				return op.always(false, 'invalid list opts')
			end
			return self.provider:list_op(opts)
		end,
	}
end

local function shell_main(self)
	local shell_scope = assert(self.scope, 'control_store shell without scope')
	assert(self.emit_ch, 'control_store shell without emit channel')

	shell_scope:finally(function ()
		finalise_shell_scope(self, shell_scope)
	end)

	local eok1, eerr1 = fibers.perform(emit_op(self.emit_ch, 'control_store', self.id, 'meta', 'details', {
		root = self.root,
		kind = 'control_store',
	}))
	if eok1 ~= true then
		error(tostring(eerr1 or 'initial meta emit failed'), 0)
	end

	local eok2, eerr2 = fibers.perform(emit_op(self.emit_ch, 'control_store', self.id, 'state', 'status', {
		state = 'available',
	}))
	if eok2 ~= true then
		error(tostring(eerr2 or 'initial state emit failed'), 0)
	end

	control_loop.run_request_loop(self.control_ch, methods_for(self), self.logger, 'control_store')
end

function Driver:capabilities_op(emit_ch)
	return op.guard(function ()
		if self.caps_applied then
			return op.always(false, 'capabilities already applied')
		end

		self.emit_ch = emit_ch

		local cap, err = cap_types.new.ControlStoreCapability(self.id, self.control_ch)
		if not cap then
			return op.always(false, tostring(err))
		end

		self.caps_applied = true
		return op.always(true, { cap })
	end)
end

---@param owner_scope Scope
function Driver:start_op(owner_scope)
	assert(owner_scope ~= nil, 'control_store driver start_op: owner_scope is required')

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

		local shell_scope, serr = owner_scope:child()
		if not shell_scope then
			return op.always(false, tostring(serr))
		end

		self.scope = shell_scope

		local ok, err = shell_scope:spawn(function ()
			return shell_main(self)
		end)
		if not ok then
			self.scope = nil
			shell_scope:cancel(tostring(err or 'shell spawn failed'))
			return op.always(false, tostring(err))
		end

		self.started = true
		return op.always(true, nil)
	end)
end

function Driver:terminate(reason)
	if self.scope then
		self.scope:cancel(reason or 'control_store driver terminated')
	end
	self.started = false
	self.scope = nil
	return true, nil
end

function Driver:shutdown_op(timeout)
	timeout = timeout or DEFAULT_STOP_TIMEOUT

	return op.guard(function ()
		if not self.started or not self.scope then
			return op.always(true, nil)
		end

		local shell_scope = self.scope
		shell_scope:cancel()

		return fibers.boolean_choice(
			shell_scope:join_op():wrap(function ()
				finalise_shell_scope(self, shell_scope)
				return true, nil
			end),
			sleep.sleep_op(timeout):wrap(function ()
				return false, 'control_store driver stop timeout'
			end)
		):wrap(function (completed, a, b)
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
---@param root string
---@param logger table|nil
---@return ControlStoreDriver
function M.new(id, root, logger)
	assert(type(id) == 'string' and id ~= '', 'control_store.new: invalid id')
	assert(type(root) == 'string' and root ~= '', 'control_store.new: invalid root')

	return setmetatable({
		id           = id,
		root         = root,
		scope        = nil,
		control_ch   = channel.new(CONTROL_Q_LEN),
		emit_ch      = nil,
		logger       = logger,
		provider     = provider_mod.new(root, logger),
		started      = false,
		caps_applied = false,
	}, Driver)
end

M.Driver = Driver
return M
