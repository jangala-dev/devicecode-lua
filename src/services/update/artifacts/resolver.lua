-- services/update/artifacts/resolver.lua
--
-- Scoped artifact resolution helpers. Resolution may create a temporary
-- artifact-like resource; ownership is represented through artifacts.lifetime
-- and must be transferred explicitly after durable handoff.

local fibers   = require 'fibers'
local lifetime = require 'services.update.artifacts.lifetime'
local model    = require 'services.update.model'

local M = {}

local function copy(v) return model.deep_copy(v) end


local function artifact_snapshot(artifact)
	if type(artifact) == 'table' and type(artifact.describe) == 'function' then
		local ok, rec = pcall(function () return artifact:describe() end)
		if ok and type(rec) == 'table' then
			rec = copy(rec)
			rec.ref = rec.ref or rec.artifact_ref
			rec.id = rec.id or rec.artifact_ref or rec.ref
			return rec
		end
	end
	local snap = copy(artifact)
	if type(snap) == 'table' then
		snap.ref = snap.ref or snap.artifact_ref
		snap.id = snap.id or snap.artifact_ref or snap.ref
	end
	return snap
end

local function perform_op(ev, label)
	local a, b = fibers.perform(ev)
	if a == nil or a == false then
		error(b or label or 'artifact_operation_failed', 0)
	end
	return a, b
end

local function import_source(scope, store, source, ctx)
	if type(store) ~= 'table' then error('artifact store required', 0) end
	source = copy(source or {})
	ctx = copy(ctx or {})

	local meta = copy(source.meta or source.metadata or ctx.metadata or {})
	meta.component = meta.component or ctx.component

	if source.kind == 'file' or source.path ~= nil then
		if type(store.import_path_op) ~= 'function' then
			error('artifact store has no import_path_op', 0)
		end
		return perform_op(store:import_path_op(source.path, meta, {
			policy = source.policy or ctx.policy,
			copy = source.copy,
		}), 'artifact_import_path_failed')
	end

	if type(store.import_source_op) ~= 'function' then
		error('artifact store has no import_source_op', 0)
	end
	return perform_op(store:import_source_op(source.source or source, meta, {
		policy = source.policy or ctx.policy,
	}), 'artifact_import_source_failed')
end

function M.resolve_worker(scope, params)
	if type(scope) ~= 'table' or type(scope.finally) ~= 'function' then
		error('artifact resolver must run inside a worker-owned scope', 2)
	end
	params = params or {}
	local artifact
	if params.artifact ~= nil then
		artifact = params.artifact
	elseif params.ref ~= nil then
		artifact = { ref = params.ref }
	else
		artifact = import_source(scope, assert(params.store, 'artifact store required'), params.source or params, {
			component = params.component,
			metadata = params.metadata,
		})
	end

	local owned
	if lifetime.has_immediate_cleanup(artifact) then
		local err
		owned, err = lifetime.own(scope, artifact, {
			reason = params.cleanup_reason or 'artifact resolution scope closed',
		})
		if not owned then error(err or 'artifact_lifetime_own_failed', 0) end
	end

	local snap = artifact_snapshot(artifact)
	return {
		tag = 'artifact_resolved',
		component = params.component,
		artifact = artifact,
		owned = owned,
		snapshot = snap,
	}
end

return M
