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

local function perform_op(ev, label)
	local a, b = fibers.perform(ev)
	if a == nil or a == false then
		error(b or label or 'artifact_operation_failed', 0)
	end
	return a, b
end

local function import_source(scope, store, source, ctx)
	if type(store) ~= 'table' then error('artifact store required', 0) end
	if type(store.import_op) == 'function' then
		return perform_op(store:import_op(copy(source or {}), copy(ctx or {})), 'artifact_import_failed')
	end
	if type(store.probe_op) == 'function' then
		return perform_op(store:probe_op(copy(source or {})), 'artifact_probe_failed')
	end
	if type(store.create_artifact_op) == 'function' then
		return perform_op(store:create_artifact_op(copy(source or {}), copy(ctx or {})), 'artifact_create_failed')
	end
	error('artifact store has no import operation', 0)
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

	local owned, err = lifetime.own(scope, artifact, {
		reason = params.cleanup_reason or 'artifact resolution scope closed',
	})
	if not owned then error(err or 'artifact_lifetime_own_failed', 0) end

	return {
		tag = 'artifact_resolved',
		component = params.component,
		artifact = artifact,
		owned = owned,
		snapshot = copy(artifact),
	}
end

return M
