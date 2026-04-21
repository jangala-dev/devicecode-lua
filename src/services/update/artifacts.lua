local cap_sdk = require 'services.hal.sdk.cap'

local M = {}
local Artifacts = {}
Artifacts.__index = Artifacts

function M.new(ctx)
    return setmetatable({ ctx = ctx }, Artifacts)
end

function Artifacts:policy_for_component(component)
    local cfg = self.ctx.state.cfg.artifacts
    return cfg.policies[component] or cfg.default_policy or 'prefer_durable'
end

function Artifacts:snapshot(artefact)
    if type(artefact) ~= 'table' or type(artefact.describe) ~= 'function' then
        return nil, 'invalid_artefact'
    end
    local rec = artefact:describe()
    if type(rec) ~= 'table' then return nil, 'invalid_artefact_record' end
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
    local meta = { kind = 'update', component = component, metadata = metadata }
    local opts_ = assert(cap_sdk.args.new.ArtifactStoreImportPathOpts(path, meta, self:policy_for_component(component)))
    local reply, err = self.ctx.artifact_cap:call_control('import_path', opts_)
    if not reply then return nil, nil, err end
    if reply.ok ~= true then return nil, nil, reply.reason end
    local artefact = reply.reason
    local rec, rerr = self:snapshot(artefact)
    if not rec then return nil, nil, rerr end
    return artefact:ref(), rec, nil
end

function Artifacts:resolve_job_artifact(payload)
    local component = assert(payload.component, 'component required')
    local artifact = payload.artifact
    if type(artifact) ~= 'table' then return nil, nil, 'artifact_required' end

    if artifact.kind == 'import_path' then
        if type(artifact.path) ~= 'string' or artifact.path == '' then return nil, nil, 'invalid_artifact_path' end
        return self:import_path(artifact.path, component, payload.metadata)
    elseif artifact.kind == 'ref' then
        if type(artifact.ref) ~= 'string' or artifact.ref == '' then return nil, nil, 'invalid_artifact_ref' end
        local artefact, derr = self:open(artifact.ref)
        if not artefact then return nil, nil, derr end
        local desc, derr2 = self:snapshot(artefact)
        if not desc then return nil, nil, derr2 end
        return artifact.ref, desc, nil
    end

    return nil, nil, 'invalid_artifact_kind'
end

return M
