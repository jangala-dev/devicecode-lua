-- services/update/artifacts/store_bus.lua
--
-- Bus-backed artifact store client.  This is the Update-side adapter for the
-- curated artifact-store capability surface; callers see only Ops and artifact
-- handles/sources.

local fibers = require 'fibers'
local op     = require 'fibers.op'

local cap_args = require 'services.hal.types.capability_args'

local M = {}

local Store = {}
Store.__index = Store

local function copy(v)
	if type(v) ~= 'table' then return v end
	local out = {}
	for k, val in pairs(v) do out[k] = copy(val) end
	return out
end

local function rpc_topic(id, method)
	return { 'cap', 'artifact-store', id or 'main', 'rpc', method }
end

local VOID_SUCCESS = {
	['delete'] = true,
}

local function unwrap_reply_for(method)
	return function (reply, err)
		if reply == nil then
			return nil, err
		end
		if type(reply) ~= 'table' or type(reply.ok) ~= 'boolean' then
			return nil, 'invalid_artifact_store_reply'
		end
		if reply.ok then
			if reply.reason == nil and VOID_SUCCESS[method] then
				return true, nil
			end
			return reply.reason, nil
		end
		return nil, tostring(reply.reason or err or 'artifact_store_call_failed')
	end
end

local function call_op(self, method, payload, opts)
	if type(self._conn) ~= 'table' or type(self._conn.call_op) ~= 'function' then
		return op.always(nil, 'artifact_store_bus_connection_required')
	end
	return self._conn:call_op(
		rpc_topic(self._id, method),
		payload or {},
		opts or self._call_opts
	):wrap(function (reply, err)
		return unwrap_reply_for(method)(reply, err)
	end)
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

function Store:create_sink_op(spec, opts)
	spec = copy(spec or {})
	opts = opts or {}
	local payload, perr = cap_args.new.ArtifactStoreCreateSinkOpts(
		spec.meta or spec.metadata or spec,
		spec.policy or opts.policy
	)
	if payload == nil then return op.always(nil, perr or 'invalid create sink opts') end
	return call_op(self, 'create-sink', payload, opts)
end

function Store:import_path_op(path, meta, opts)
	if type(path) == 'table' then
		opts = meta
		meta = path.meta or path.metadata
		path = path.path
	end
	opts = opts or {}
	local payload, perr = cap_args.new.ArtifactStoreImportPathOpts(path, meta or {}, opts.policy)
	if payload == nil then return op.always(nil, perr or 'invalid import path opts') end
	return call_op(self, 'import-path', payload, opts)
end

function Store:import_source_op(source, meta, opts)
	opts = opts or {}
	local payload, perr = cap_args.new.ArtifactStoreImportSourceOpts(source, meta or {}, opts.policy)
	if payload == nil then return op.always(nil, perr or 'invalid import source opts') end
	return call_op(self, 'import-source', payload, opts)
end

function Store:open_op(ref)
	if type(ref) == 'table' then ref = ref.ref or ref.artifact_ref or ref.id end
	local payload, perr = cap_args.new.ArtifactStoreOpenOpts(ref)
	if payload == nil then return op.always(nil, perr or 'invalid artifact ref') end
	return call_op(self, 'open', payload)
end

function Store:open_source_op(ref)
	return fibers.run_scope_op(function ()
		local artifact, err = fibers.perform(self:open_op(ref))
		if artifact == nil then return nil, err or 'artifact_open_failed' end
		if type(artifact.open_source_op) ~= 'function' then
			return nil, 'artifact_handle_has_no_open_source_op'
		end
		local ok_source, source_or_err = fibers.perform(artifact:open_source_op())
		if ok_source ~= true then
			return nil, source_or_err or 'artifact_source_open_failed'
		end
		return source_or_err, nil
	end):wrap(unwrap_scope_value('artifact_source_open'))
end

function Store:delete_op(ref, opts)
	if type(ref) == 'table' then ref = ref.ref or ref.artifact_ref or ref.id end
	local payload, perr = cap_args.new.ArtifactStoreDeleteOpts(ref)
	if payload == nil then return op.always(nil, perr or 'invalid artifact ref') end
	return call_op(self, 'delete', payload, opts)
end

function Store:status_op(opts)
	local payload, perr = cap_args.new.ArtifactStoreStatusOpts()
	if payload == nil then return op.always(nil, perr or 'invalid status opts') end
	return call_op(self, 'status', payload, opts)
end

function M.new(conn, opts)
	opts = opts or {}
	return setmetatable({
		_conn = conn,
		_id = opts.id or 'main',
		_call_opts = opts.call_opts,
	}, Store)
end

M.Store = Store
return M
