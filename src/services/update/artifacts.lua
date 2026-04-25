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
local mcu_image_v1 = require 'shared.mcu_image.v1'
local crypto_provider = require 'shared.crypto.provider'
local crypto_keyring = require 'shared.crypto.keyring'
local crypto_verifier = require 'shared.crypto.verifier'

local default_preflighters = {}

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
	return setmetatable({ ctx = ctx, preflighters = {} }, Artifacts)
end

function M.set_default_preflighter(component, fn)
	if fn == nil then
		default_preflighters[component] = nil
	else
		default_preflighters[component] = assert(type(fn) == 'function' and fn or nil)
	end
end

function M.reset_default_preflighters()
	for k in pairs(default_preflighters) do default_preflighters[k] = nil end
end

function Artifacts:set_preflighter(component, fn)
	if fn == nil then
		self.preflighters[component] = nil
	else
		self.preflighters[component] = assert(type(fn) == 'function' and fn or nil)
	end
end

function Artifacts:reset_preflighters()
	for k in pairs(self.preflighters) do self.preflighters[k] = nil end
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
	local verifier = nil
	local trusted = preflight.trusted_keys or preflight.keys
	if preflight.require_signature == true or (type(trusted) == 'table' and next(trusted) ~= nil) then
		if not self.ctx.signature_verify_cap then
			return nil, 'signature_verifier_unavailable'
		end
		local keyring = crypto_keyring.from_config(preflight)
		local provider = crypto_provider.from_cap(self.ctx.signature_verify_cap)
		verifier = crypto_verifier.new({ provider = provider, keyring = keyring })
	end
	local opts = {
		target = type(bundled_cfg) == 'table' and bundled_cfg.target or nil,
		require_signature = preflight.require_signature == true,
		verifier = verifier,
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
	desc = type(desc) == 'table' and desc or {}
	desc.source = desc.source or 'bundled'
	desc.bundled = true
	desc.bundled_policy = type(rec) == 'table' and rec or nil
	return ref, desc, nil
end

function Artifacts:preflighter_for(component)
	local own = self.preflighters and self.preflighters[component] or nil
	if own ~= nil then return own end
	local injected = self.ctx and self.ctx.preflighters and self.ctx.preflighters[component] or nil
	if injected ~= nil then return injected end
	local def = default_preflighters[component]
	if def ~= nil then return def end
	if component == 'mcu' then
		return function(artifacts, ref, desc, artifact_spec)
			local cfg = select(1, artifacts:bundled_cfg_for(component, artifact_spec))
			local artifact_obj, oerr = artifacts:open(ref)
			if not artifact_obj then
				return nil, oerr or 'artifact_open_failed'
			end
			local inspected, ierr = artifacts:inspect_mcu_artifact(artifact_obj, cfg)
			if not inspected then
				return nil, ierr or 'mcu_image_invalid'
			end
			desc = type(desc) == 'table' and desc or {}
			desc.mcu_image = inspected
			return desc, nil
		end
	end
	return nil
end

function Artifacts:preflight_artifact(component, ref, desc, artifact_spec)
	local fn = self:preflighter_for(component)
	if not fn then
		return desc, nil
	end
	return fn(self, ref, desc, artifact_spec, component)
end

function Artifacts:resolve_job_artifact(payload)
	local component = payload and payload.component or nil
	if type(component) ~= 'string' or component == '' then
		return nil, nil, 'component_required'
	end
	local artifact_spec = payload and payload.artifact or nil
	local ref, desc, cleanup_on_failure, err = sources.resolve(self, component, artifact_spec, payload and payload.metadata or nil)
	if not ref then return nil, nil, err end
	local preflighted, perr = self:preflight_artifact(component, ref, desc, artifact_spec)
	if not preflighted then
		if cleanup_on_failure == true then
			self:delete(ref)
		end
		return nil, nil, perr
	end
	return ref, preflighted, nil
end

return M
