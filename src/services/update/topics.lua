-- services/update/topics.lua
--
-- Pure topic construction for the update service.

local topic = require 'shared.topic'

local M = {}

local function t(...)
	return { ... }
end

local MANAGER_METHODS = {
	'status',
	'list-jobs',
	'get-job',
	'create-job',
	'start-job',
	'commit-job',
	'cancel-job',
	'retry-job',
	'discard-job',
}

local INGEST_METHODS = {
	'create',
	'append',
	'commit',
	'abort',
}

function M.config()
	return t('cfg', 'update')
end

function M.lifecycle_status()
	return t('svc', 'update', 'status')
end

function M.lifecycle_meta()
	return t('svc', 'update', 'meta')
end

function M.update_summary()
	return t('state', 'update', 'summary')
end

function M.update_component(component)
	return t('state', 'update', 'component', component)
end

function M.workflow_update_job(job_id)
	return t('state', 'workflow', 'update-job', job_id)
end

function M.workflow_artifact_ingest(ingest_id)
	return t('state', 'workflow', 'artifact-ingest', ingest_id)
end

function M.update_manager_meta(id)
	return t('cap', 'update-manager', id or 'main', 'meta')
end

function M.update_manager_status(id)
	return t('cap', 'update-manager', id or 'main', 'status')
end

function M.update_manager_rpc(method, id)
	return t('cap', 'update-manager', id or 'main', 'rpc', method)
end

function M.artifact_ingest_meta(id)
	return t('cap', 'artifact-ingest', id or 'main', 'meta')
end

function M.artifact_ingest_status(id)
	return t('cap', 'artifact-ingest', id or 'main', 'status')
end

function M.artifact_ingest_rpc(method, id)
	return t('cap', 'artifact-ingest', id or 'main', 'rpc', method)
end

function M.manager_methods()
	return topic.copy(MANAGER_METHODS)
end

function M.ingest_methods()
	return topic.copy(INGEST_METHODS)
end

function M.obs_state(name)
	return t('obs', 'v1', 'update', 'state', name)
end

return M
