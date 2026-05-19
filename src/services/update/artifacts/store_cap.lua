-- services/update/artifacts/store_cap.lua
-- Operation-shaped artifact store adapter.

local safe  = require 'coxpcall'
local fibers = require 'fibers'
local op    = require 'fibers.op'
local model = require 'services.update.model'

local M = {}
local Store = {}
Store.__index = Store

local function copy(v) return model.deep_copy(v) end
local function is_op(v) return type(v) == 'table' and getmetatable(v) == op.Op end

local function immediate(fn, ...)
	local args = { n = select('#', ...), ... }
	local ok, a, b = safe.pcall(function () return fn(unpack(args, 1, args.n)) end)
	if not ok then return op.always(nil, tostring(a)) end
	return op.always(a, b)
end


local function unwrap_scope_value(label)
	return function (st, report, value, err)
		if st == 'ok' then
			if value == nil then return nil, err or (label and (label .. '_failed')) or 'operation_failed' end
			return value, err
		end
		return nil, value or err or report or st or (label and (label .. '_failed')) or 'operation_failed'
	end
end

function Store:create_sink_op(spec)
	local b = self._backend
	if type(b.create_sink_op) == 'function' then
		spec = copy(spec or {})
		local ev = b:create_sink_op(spec.meta or spec.metadata or spec, { policy = spec.policy })
		if not is_op(ev) then return op.always(nil, 'create_sink_op did not return an Op') end
		return ev
	end
	if type(b.create_sink) == 'function' then
		return immediate(function () return b:create_sink(copy(spec or {})) end)
	end
	return op.always(nil, 'create_sink not supported')
end


function Store:import_path_op(path, meta, opts)
	local b = self._backend
	if type(path) == 'table' then
		opts = meta
		meta = path.meta or path.metadata
		path = path.path
	end
	if type(b.import_path_op) == 'function' then
		local ev = b:import_path_op(path, copy(meta or {}), copy(opts or {}))
		if not is_op(ev) then return op.always(nil, 'import_path_op did not return an Op') end
		return ev
	end
	if type(b.import_path) == 'function' then
		return immediate(function () return b:import_path(path, copy(meta or {}), copy(opts or {})) end)
	end
	return op.always(nil, 'import_path not supported')
end

function Store:import_source_op(source, meta, opts)
	local b = self._backend
	if type(b.import_source_op) == 'function' then
		local ev = b:import_source_op(source, copy(meta or {}), copy(opts or {}))
		if not is_op(ev) then return op.always(nil, 'import_source_op did not return an Op') end
		return ev
	end
	if type(b.import_source) == 'function' then
		return immediate(function () return b:import_source(source, copy(meta or {}), copy(opts or {})) end)
	end
	return op.always(nil, 'import_source not supported')
end

function Store:import_op(source, ctx)
	ctx = ctx or {}
	if type(source) == 'table' and (source.kind == 'file' or source.path ~= nil) then
		return self:import_path_op(source.path, source.meta or source.metadata or ctx.metadata, {
			copy = source.copy,
			policy = source.policy or ctx.policy,
		})
	end
	return self:import_source_op(source, ctx.metadata, { policy = ctx.policy })
end

function Store:open_op(ref)
	local b = self._backend
	if type(ref) == 'table' then ref = ref.ref or ref.artifact_ref or ref.id end
	if type(b.open_op) == 'function' then
		local ev = b:open_op(ref)
		if not is_op(ev) then return op.always(nil, 'open_op did not return an Op') end
		return ev
	end
	if type(b.open) == 'function' then
		return immediate(function () return b:open(ref) end)
	end
	return op.always(nil, 'open not supported')
end

function Store:open_source_op(ref)
	return fibers.run_scope_op(function ()
		local artifact, err = fibers.perform(self:open_op(ref))
		if artifact == nil then return nil, err or 'artifact_open_failed' end
		if type(artifact.open_source_op) ~= 'function' then
			return nil, 'artifact_handle_has_no_open_source_op'
		end
		local ok_or_source, source_or_err = fibers.perform(artifact:open_source_op())
		if ok_or_source == true then
			return source_or_err, nil
		end
		if ok_or_source ~= nil and type(ok_or_source) == 'table' then
			return ok_or_source, source_or_err
		end
		return nil, source_or_err or ok_or_source or 'artifact_source_open_failed'
	end):wrap(unwrap_scope_value('artifact_source_open'))
end

function Store:probe_op(source)
	local b = self._backend
	if type(b.probe_op) == 'function' then
		local ev = b:probe_op(copy(source or {}))
		if not is_op(ev) then return op.always(nil, 'probe_op did not return an Op') end
		return ev
	end
	if type(b.probe) == 'function' then
		return immediate(function () return b:probe(copy(source or {})) end)
	end
	return op.always(nil, 'probe not supported')
end

function M.wrap(backend)
	if type(backend) ~= 'table' then error('artifact store backend table required', 2) end
	return setmetatable({ _backend = backend }, Store)
end

M.Store = Store
return M
