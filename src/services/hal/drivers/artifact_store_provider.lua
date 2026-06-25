---@module 'services.hal.drivers.artifact_store_provider'

local fibers       = require 'fibers'
local sleep        = require 'fibers.sleep'
local op           = require 'fibers.op'
local channel      = require 'fibers.channel'

local hal_types    = require 'services.hal.types.core'
local cap_types    = require 'services.hal.types.capabilities'
local cap_args     = require 'services.hal.types.capability_args'
local control_loop = require 'services.hal.support.control_loop'
local tablex       = require 'shared.table'

local backend_mod  = require 'services.hal.drivers.artifact_store'

local M = {}

local CONTROL_Q_LEN         = 8
local DEFAULT_STOP_TIMEOUT  = 5.0

---@class ArtifactStoreProvider
---@field id string
---@field opts table
---@field logger table|nil
---@field scope Scope|nil
---@field control_ch Channel
---@field emit_ch Channel|nil
---@field backend any
---@field started boolean
---@field caps_applied boolean
local Driver = {}
Driver.__index = Driver

local deep_copy = tablex.deep_copy


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
		status = function (opts, _request)
			if opts ~= nil and getmetatable(opts) ~= cap_args.ArtifactStoreStatusOpts then
				return op.always(false, 'invalid status opts')
			end
			return self.backend:status_op()
		end,

		['create-sink'] = function (opts, _request)
			if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ArtifactStoreCreateSinkOpts then
				return op.always(false, 'invalid create-sink opts')
			end
			return self.backend:create_sink_op(opts.meta, {
				policy = opts.policy,
			})
		end,

		['import-path'] = function (opts, _request)
			if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ArtifactStoreImportPathOpts then
				return op.always(false, 'invalid import-path opts')
			end
			return self.backend:import_path_op(opts.path, opts.meta, {
				policy = opts.policy,
			})
		end,

		['import-source'] = function (opts, _request)
			if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ArtifactStoreImportSourceOpts then
				return op.always(false, 'invalid import-source opts')
			end
			return self.backend:import_source_op(opts.source, opts.meta, {
				policy = opts.policy,
			})
		end,

		open = function (opts, _request)
			if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ArtifactStoreOpenOpts then
				return op.always(false, 'invalid open opts')
			end
			return self.backend:open_op(opts.artifact_ref)
		end,

		delete = function (opts, _request)
			if type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.ArtifactStoreDeleteOpts then
				return op.always(false, 'invalid delete opts')
			end
			return self.backend:delete_op(opts.artifact_ref)
		end,
	}
end

local function shell_main(self)
	local shell_scope = assert(self.scope, 'artifact_store shell without scope')
	assert(self.emit_ch, 'artifact_store shell without emit channel')

	shell_scope:finally(function ()
		finalise_shell_scope(self, shell_scope)
	end)

	local ok_meta, meta_err = fibers.perform(emit_op(
		self.emit_ch,
		'artifact-store',
		self.id,
		'meta',
		'info',
		{
			provider = 'hal.artifact_store',
			version = 2,
			transient_root = self.backend.transient_root,
			durable_root = self.backend.durable_root,
			durable_enabled = self.backend.durable_enabled,
			import_root = self.backend.import_root,
		}
	))
	if ok_meta ~= true then
		error(tostring(meta_err or 'initial meta emit failed'), 0)
	end

	local ok_state, state_err = fibers.perform(emit_op(
		self.emit_ch,
		'artifact-store',
		self.id,
		'state',
		'status',
		{ state = 'available' }
	))
	if ok_state ~= true then
		error(tostring(state_err or 'initial state emit failed'), 0)
	end

	control_loop.run_request_loop(
		self.control_ch,
		methods_for(self),
		self.logger,
		'artifact-store'
	)
end

function Driver:capabilities_op(emit_ch)
	return op.guard(function ()
		if self.caps_applied then
			return op.always(false, 'capabilities already applied')
		end

		self.emit_ch = emit_ch

		local cap, err = cap_types.new.ArtifactStoreCapability(self.id, self.control_ch)
		if not cap then
			return op.always(false, tostring(err))
		end

		self.caps_applied = true
		return op.always(true, { cap })
	end)
end

function Driver:start_op(owner_scope)
	assert(owner_scope ~= nil, 'artifact_store provider start_op: owner_scope is required')

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
			shell_scope:cancel(tostring(serr or 'shell spawn failed'))
			return op.always(false, tostring(serr))
		end

		self.started = true
		return op.always(true, nil)
	end)
end

function Driver:terminate(reason)
	if self.scope then
		self.scope:cancel(reason or 'artifact_store provider terminated')
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
		shell_scope:cancel('artifact_store provider stopped')

		return fibers.boolean_choice(
			shell_scope:join_op():wrap(function ()
				finalise_shell_scope(self, shell_scope)
				return true, nil
			end),
			sleep.sleep_op(timeout):wrap(function ()
				return false, 'artifact_store provider stop timeout'
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

function M.new(id, opts, logger)
	assert(type(id) == 'string' and id ~= '', 'artifact_store_provider.new: invalid id')

	local raw_opts = opts or {}
	local injected_backend = raw_opts.backend
	opts = deep_copy(raw_opts)

	return setmetatable({
		id           = id,
		opts         = opts,
		logger       = logger,
		scope        = nil,
		control_ch   = channel.new(CONTROL_Q_LEN),
		emit_ch      = nil,
		backend      = injected_backend or backend_mod.new(opts, logger),
		started      = false,
		caps_applied = false,
	}, Driver)
end

M.Driver = Driver
return M
