-- services/update/artifacts.lua
--
-- Update artefact resolution helpers.
--
-- Responsibilities:
--   * choose per-component artefact storage policy
--   * talk to the HAL artefact store capability
--   * resolve user/job payloads into:
--       - stored artefact refs
--       - stable artefact snapshots used by update jobs
--
-- This module does not own job lifecycle or publication.

local cap_sdk = require 'services.hal.sdk.cap'
local sources = require 'services.update.artifact_sources'
local mcu_image_v1 = require 'services.update.mcu_image_v1'


local function merge_meta(a, b)
	local out = {}
	for _, src in ipairs({ a, b }) do
		if type(src) == 'table' then
			for k, v in pairs(src) do out[k] = v end
		end
	end
	return out
end

local M = {}
local Artifacts = {}
Artifacts.__index = Artifacts

function M.new(ctx)
	return setmetatable({ ctx = ctx }, Artifacts)
end

function Artifacts:policy_for_component(component)
	local cfg = self.ctx.state.cfg.artifacts or {}
	local policies = type(cfg.policies) == 'table' and cfg.policies or {}
	return policies[component] or cfg.default_policy or 'prefer_durable'
end

function Artifacts:describe_artifact(artifact)
	if type(artifact) ~= 'table' or type(artifact.describe) ~= 'function' then
		return nil, 'invalid_artefact'
	end
	local rec = artifact:describe()
	if type(rec) ~= 'table' then
		return nil, 'invalid_artefact_record'
	end
	return rec, nil
end

function Artifacts:open(ref)
	local opts_ = assert(cap_sdk.args.new.ArtifactStoreOpenOpts(ref))
	local reply, err = self.ctx.artifact_cap:call_control('open', opts_)
	if not reply then return nil, err end
	if reply.ok ~= true then return nil, reply.reason end
	return reply.reason, nil
end

function Artifacts:delete(ref)
	local opts_ = assert(cap_sdk.args.new.ArtifactStoreDeleteOpts(ref))
	local reply, err = self.ctx.artifact_cap:call_control('delete', opts_)
	if not reply then return nil, err end
	if reply.ok ~= true then return nil, reply.reason end
	return true, nil
end

function Artifacts:import_path(path, component, metadata)
	local meta = {
		kind = 'update',
		component = component,
		metadata = metadata,
	}
	local opts_ = assert(cap_sdk.args.new.ArtifactStoreImportPathOpts(
		path,
		meta,
		self:policy_for_component(component)
	))
	local reply, err = self.ctx.artifact_cap:call_control('import_path', opts_)
	if not reply then return nil, nil, err end
	if reply.ok ~= true then return nil, nil, reply.reason end

	local artifact = reply.reason
	local rec, rerr = self:describe_artifact(artifact)
	if not rec then return nil, nil, rerr end

	return artifact:ref(), rec, nil
end


function Artifacts:bundled_cfg_for(component, artifact)
	local cfg = self.ctx.state.cfg.bundled or {}
	local components = type(cfg.components) == 'table' and cfg.components or {}
	local rec = type(components[component]) == 'table' and components[component] or {}
	local source = type(rec.source) == 'table' and rec.source or {}
	local out = {}
	for k, v in pairs(source) do out[k] = v end
	if type(artifact) == 'table' then
		for k, v in pairs(artifact) do
			if k ~= 'kind' and v ~= nil then out[k] = v end
		end
	end
	out.preflight = type(out.preflight) == 'table' and out.preflight or rec.preflight
	out.target = type(out.target) == 'table' and out.target or rec.target
	return out, rec
end

function Artifacts:inspect_mcu_artifact(artifact, bundled_cfg)
	if not (artifact and type(artifact.open_source) == 'function') then
		return nil, 'invalid_artefact'
	end
	local preflight = type(bundled_cfg) == 'table' and bundled_cfg.preflight or nil
	preflight = type(preflight) == 'table' and preflight or {}
	local opts = {
		target = type(bundled_cfg) == 'table' and bundled_cfg.target or nil,
		require_signature = preflight.require_signature == true,
	}
	return mcu_image_v1.inspect_source(artifact, opts)
end

function Artifacts:import_bundled(component, artifact, metadata)
	local cfg, rec = self:bundled_cfg_for(component, artifact)
	local path = cfg.path or cfg.image_path
	if type(path) ~= 'string' or path == '' then
		return nil, nil, 'bundled_path_required'
	end

	local meta = merge_meta(metadata, {
		source = 'bundled',
		bundled = true,
		bundled_path = path,
	})
	local ref, desc, err = self:import_path(path, component, meta)
	if not ref then return nil, nil, err end

	local artifact_obj, oerr = self:open(ref)
	if not artifact_obj then
		self:delete(ref)
		return nil, nil, oerr or 'artifact_open_failed'
	end

	local inspected, ierr = self:inspect_mcu_artifact(artifact_obj, cfg)
	if not inspected then
		self:delete(ref)
		return nil, nil, ierr or 'mcu_image_invalid'
	end

	desc = type(desc) == 'table' and desc or {}
	desc.mcu_image = inspected
	desc.source = desc.source or 'bundled'
	desc.bundled = true
	desc.bundled_policy = type(rec) == 'table' and rec or nil
	return ref, desc, nil
end

function Artifacts:resolve_job_artifact(payload)
	local component = payload and payload.component or nil
	if type(component) ~= 'string' or component == '' then
		return nil, nil, 'component_required'
	end
	return sources.resolve(self, component, payload and payload.artifact or nil, payload and payload.metadata or nil)
end

return M
