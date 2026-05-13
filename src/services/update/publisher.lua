-- services/update/publisher.lua
--
-- Retained publication owner for update models.
--
-- Publication is separated from update policy. The service supervises this as a
-- normal scoped component; publisher.start is retained as a small convenience for
-- tests and direct embedding.

local fibers      = require 'fibers'
local scoped_work = require 'devicecode.support.scoped_work'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local topics      = require 'services.update.topics'
local projection  = require 'services.update.projection'
local model_mod   = require 'services.update.model'

local M = {}

local Publisher = {}
Publisher.__index = Publisher

local function copy(v)
	return model_mod.deep_copy(v)
end

local function publish_snapshot(conn, topic, project, snapshot)
	local ok, err = bus_cleanup.retain(conn, topic, project(snapshot))
	if ok ~= true then
		return nil, err or 'update publisher retain failed'
	end
	return true, nil
end

local function retain_payload(conn, topic, payload)
	local ok, err = bus_cleanup.retain(conn, topic, payload)
	if ok ~= true then return nil, err end
	return true, nil
end

local function unretain(conn, topic)
	local ok, err = bus_cleanup.unretain(conn, topic)
	if ok ~= true then return nil, err end
	return true, nil
end

local function require_params(scope, params, name)
	if type(scope) ~= 'table' then
		error(name .. ': scope required', 2)
	end
	if type(params) ~= 'table' then
		error(name .. ': params table required', 2)
	end
	if params.conn == nil then
		error(name .. ': conn required', 2)
	end
	if params.model == nil then
		error(name .. ': model required', 2)
	end
end

local function jobs_by_id(snapshot)
	local jobs = snapshot and snapshot.jobs or nil
	return type(jobs) == 'table' and type(jobs.by_id) == 'table' and jobs.by_id or {}
end

local function ingest_by_id(snapshot)
	local ingest = snapshot and snapshot.ingest or nil
	if type(ingest) ~= 'table' then return {} end
	if type(ingest.by_id) == 'table' then return ingest.by_id end

	-- Generation-owned ingest state snapshots are keyed directly by ingest id.
	-- The publisher accepts both that internal shape and the public { by_id = ... }
	-- shape so workflow publication is not coupled to one model owner.
	local out = {}
	for id, rec in pairs(ingest) do
		if type(id) == 'string' and type(rec) == 'table' then
			out[id] = rec
		end
	end
	return out
end

local function component_summaries(snapshot)
	local out = {}
	for _, job in pairs(jobs_by_id(snapshot)) do
		local component = type(job) == 'table' and job.component or nil
		if type(component) == 'string' and component ~= '' then
			local rec = out[component]
			if not rec then
				rec = {
					kind = 'update.component',
					component = component,
					jobs = { count = 0, by_id = {} },
					active = nil,
					last = nil,
				}
				out[component] = rec
			end
			rec.jobs.count = rec.jobs.count + 1
			rec.jobs.by_id[job.job_id] = copy(job)
			if job.active ~= nil or job.active_intent ~= nil or job.active_token ~= nil then
				rec.active = copy(job)
			end
			rec.last = copy(job)
		end
	end
	return out
end

local function retained_set_clear(conn, retained, make_topic)
	for id in pairs(retained) do
		unretain(conn, make_topic(id))
		retained[id] = nil
	end
end

local function sync_workflows(conn, retained, snapshot)
	local current_jobs = {}
	for id, job in pairs(jobs_by_id(snapshot)) do
		current_jobs[id] = true
		local ok, err = retain_payload(conn, topics.workflow_update_job(id), projection.job(job))
		if ok ~= true then return nil, err or 'update workflow job retain failed' end
		retained.jobs[id] = true
	end
	for id in pairs(retained.jobs) do
		if not current_jobs[id] then
			local ok, err = unretain(conn, topics.workflow_update_job(id))
			if ok ~= true then return nil, err or 'update workflow job unretain failed' end
			retained.jobs[id] = nil
		end
	end

	local current_ingest = {}
	for id, rec in pairs(ingest_by_id(snapshot)) do
		current_ingest[id] = true
		local ok, err = retain_payload(conn, topics.workflow_artifact_ingest(id), projection.ingest(rec))
		if ok ~= true then return nil, err or 'artifact ingest workflow retain failed' end
		retained.ingest[id] = true
	end
	for id in pairs(retained.ingest) do
		if not current_ingest[id] then
			local ok, err = unretain(conn, topics.workflow_artifact_ingest(id))
			if ok ~= true then return nil, err or 'artifact ingest workflow unretain failed' end
			retained.ingest[id] = nil
		end
	end
	return true, nil
end

local function sync_components(conn, retained, snapshot)
	local current = component_summaries(snapshot)
	for id, payload in pairs(current) do
		local ok, err = retain_payload(conn, topics.update_component(id), payload)
		if ok ~= true then return nil, err or 'update component retain failed' end
		retained.components[id] = true
	end
	for id in pairs(retained.components) do
		if current[id] == nil then
			local ok, err = unretain(conn, topics.update_component(id))
			if ok ~= true then return nil, err or 'update component unretain failed' end
			retained.components[id] = nil
		end
	end
	return true, nil
end

local function publish_capabilities(conn, snapshot)
	local mgr_methods = topics.manager_methods()
	local ingest_methods = topics.ingest_methods()
	local ok, err = retain_payload(conn, topics.update_manager_meta(), {
		kind = 'cap.update-manager',
		class = 'update-manager',
		id = 'main',
		owner = 'update',
		methods = mgr_methods,
		canonical_state = topics.update_summary(),
		workflow_family = { 'state', 'workflow', 'update-job' },
	})
	if ok ~= true then return nil, err end
	ok, err = retain_payload(conn, topics.update_manager_status(), {
		state = snapshot.ready and 'available' or 'unavailable',
		available = snapshot.ready == true,
		ready = snapshot.ready == true,
		reason = snapshot.reason,
	})
	if ok ~= true then return nil, err end

	ok, err = retain_payload(conn, topics.artifact_ingest_meta(), {
		kind = 'cap.artifact-ingest',
		class = 'artifact-ingest',
		id = 'main',
		owner = 'update',
		methods = ingest_methods,
		workflow_family = { 'state', 'workflow', 'artifact-ingest' },
	})
	if ok ~= true then return nil, err end
	return retain_payload(conn, topics.artifact_ingest_status(), {
		state = snapshot.ready and 'available' or 'unavailable',
		available = snapshot.ready == true,
		ready = snapshot.ready == true,
		reason = snapshot.reason,
	})
end

local function publish_all(conn, retained, snapshot)
	local ok, err = publish_snapshot(conn, topics.update_summary(), projection.service_state, snapshot)
	if ok ~= true then return nil, err end
	ok, err = publish_capabilities(conn, snapshot)
	if ok ~= true then return nil, err end
	ok, err = sync_workflows(conn, retained, snapshot)
	if ok ~= true then return nil, err end
	return sync_components(conn, retained, snapshot)
end

--- Publisher worker body.
function M.run(scope, params)
	require_params(scope, params, 'publisher.run')

	local conn = params.conn
	local model = params.model
	local seen = model:version()
	local retained = {
		jobs = {},
		ingest = {},
		components = {},
	}

	scope:finally(function ()
		bus_cleanup.unretain(conn, topics.update_summary())
		bus_cleanup.unretain(conn, topics.update_manager_meta())
		bus_cleanup.unretain(conn, topics.update_manager_status())
		bus_cleanup.unretain(conn, topics.artifact_ingest_meta())
		bus_cleanup.unretain(conn, topics.artifact_ingest_status())
		retained_set_clear(conn, retained.jobs, topics.workflow_update_job)
		retained_set_clear(conn, retained.ingest, topics.workflow_artifact_ingest)
		retained_set_clear(conn, retained.components, topics.update_component)
	end)

	local initial = model:snapshot()
	local ok, err = publish_all(conn, retained, initial)
	if ok ~= true then
		error(err or 'publisher_initial_publication_failed', 0)
	end

	while true do
		local version, snapshot = fibers.perform(model:changed_op(seen))
		if version == nil then
			return {
				role = 'update_publisher',
				reason = 'model_closed',
			}
		end

		seen = version

		local ok_pub, pub_err = publish_all(conn, retained, snapshot)
		if ok_pub ~= true then
			error(pub_err or 'update publisher retain failed', 0)
		end
	end
end

function Publisher:stop(reason)
	if self._handle and self._handle.cancel then
		self._handle:cancel(reason or 'publisher_stopped')
	end
	return true
end

function M.start(scope, params)
	require_params(scope, params, 'publisher.start')

	local handle, err = scoped_work.start {
		lifetime_scope = scope,
		reaper_scope   = scope,
		report_scope   = scope,

		identity = {
			kind = 'component_done',
			component = 'publisher',
		},

		run = function (child_scope)
			return M.run(child_scope, params)
		end,

		report = function (ev)
			if ev.status == 'failed' then
				return nil, ev.primary or 'publisher_failed'
			end
			return true, nil
		end,
	}

	if not handle then
		return nil, err
	end

	return setmetatable({
		_handle = handle,
		_model = params.model,
		_conn = params.conn,
		state_topic = topics.update_summary(),
	}, Publisher), nil
end

M.Publisher = Publisher

return M
