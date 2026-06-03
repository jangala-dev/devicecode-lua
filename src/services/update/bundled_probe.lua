-- services/update/bundled_probe.lua
--
-- Scoped desired-artifact probing/import for bundled update policy.
--
-- The normal fixed-path path imports the configured file into the artifact
-- store, so downstream Update code always receives the same artifact_ref shape
-- as the browser-ingest path. Pure probe_op backends remain supported for
-- tests and non-importing stores.

local fibers = require 'fibers'
local scoped_work = require 'devicecode.support.scoped_work'
local queue = require 'devicecode.support.queue'
local tablex = require 'shared.table'
local safe = require 'coxpcall'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

local function artifact_snapshot(v)
	if type(v) == 'table' and type(v.describe) == 'function' then
		local ok, rec = safe.pcall(function () return v:describe() end)
		if ok and type(rec) == 'table' then
			rec = copy(rec)
			rec.ref = rec.ref or rec.artifact_ref
			rec.id = rec.id or rec.artifact_ref or rec.ref
			return rec
		end
	end
	local out = copy(v)
	if type(out) == 'table' then
		out.ref = out.ref or out.artifact_ref
		out.id = out.id or out.artifact_ref or out.ref
	end
	return out
end

local function import_or_probe_op(store, source, component)
	source = source or {}
	local meta = copy(source.meta or source.metadata or {})
	meta.component = meta.component or component
	meta.source = meta.source or 'bundled'

	local opts = {
		policy = source.policy,
		copy = source.copy,
	}

	if (source.kind == 'file' or source.path ~= nil) and type(store.import_path_op) == 'function' then
		return store:import_path_op(source.path, meta, opts)
	end

	if type(store.import_source_op) == 'function' and source.source ~= nil then
		return store:import_source_op(source.source, meta, opts)
	end

	if type(store.probe_op) == 'function' then
		return store:probe_op(source)
	end


	return require('fibers.op').always(nil, 'artifact_store_import_or_probe_not_supported')
end

function M.run(scope, params)
	params = params or {}
	local store = assert(params.artifact_store, 'bundled_probe: artifact_store required')
	local source = assert(params.source, 'bundled_probe: source required')
	local result, err = fibers.perform(import_or_probe_op(store, source, params.component))
	if result == nil then error(err or 'bundled_probe_failed', 0) end
	local desired = artifact_snapshot(result)
	return {
		tag = 'bundled_desired',
		component = params.component,
		desired = desired,
		artifact = desired,
		artifact_ref = type(desired) == 'table' and (desired.artifact_ref or desired.ref or desired.id) or nil,
	}
end

function M.start(spec)
	spec = spec or {}
	return scoped_work.start {
		lifetime_scope = assert(spec.lifetime_scope, 'lifetime_scope required'),
		reaper_scope   = spec.reaper_scope or spec.lifetime_scope,
		report_scope   = assert(spec.report_scope or spec.lifetime_scope, 'report_scope required'),

		identity = {
			kind       = 'bundled_probe_done',
			service_id = spec.service_id,
			generation = spec.generation,
			component  = spec.component,
		},

		run = function (scope)
			return M.run(scope, spec)
		end,

		report = function (ev)
			if not spec.done_tx then return true, nil end
			return queue.try_admit_required(
				spec.done_tx,
				ev,
				'update_bundled_probe_completion_report_failed'
			)
		end,
	}
end

return M
