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
	local seen = {}
	local cfg = snapshot and snapshot.config or nil
	if type(cfg) == 'table' and type(cfg.components) == 'table' then
		for id in pairs(cfg.components) do seen[id] = true end
	end
	for _, job in pairs(jobs_by_id(snapshot)) do
		if type(job) == 'table' and type(job.component) == 'string' and job.component ~= '' then
			seen[job.component] = true
		end
	end
	for id in pairs(seen) do
		out[id] = projection.component_summary(id, snapshot)
	end
	return out
end

local function retained_set_clear(conn, retained, make_topic)
	for id in pairs(retained) do
		unretain(conn, make_topic(id))
		retained[id] = nil
	end
end

local function unretain_workflow_job(conn, id)
	local ok, err = unretain(conn, topics.workflow_update_job(id))
	if ok ~= true then return nil, err or 'update workflow job unretain failed' end
	ok, err = unretain(conn, topics.workflow_update_job_timeline(id))
	if ok ~= true then return nil, err or 'update workflow job timeline unretain failed' end
	return true, nil
end

local function sync_workflows(conn, retained, snapshot)
	-- Workflow job/timeline retained topics were useful during early development but
	-- are not device state. Normal publication no longer creates them. This cleanup
	-- removes anything retained by this publisher and any legacy job IDs reported by
	-- the destructive startup scrub.
	for id in pairs(retained.jobs or {}) do
		local ok, err = unretain_workflow_job(conn, id)
		if ok ~= true then return nil, err end
		retained.jobs[id] = nil
	end
	local adoption = type(snapshot) == 'table' and type(snapshot.adoption) == 'table' and snapshot.adoption or {}
	local seen_legacy = {}
	local single = type(adoption.single_job) == 'table' and adoption.single_job or {}
	for _, id in ipairs(single.legacy_job_ids or {}) do
		if id ~= nil and not seen_legacy[id] then
			seen_legacy[id] = true
			local ok, err = unretain_workflow_job(conn, id)
			if ok ~= true then return nil, err end
		end
	end
	for _, row in ipairs(adoption.pruned or {}) do
		local id = type(row) == 'table' and row.job_id or nil
		if id ~= nil and not seen_legacy[id] then
			seen_legacy[id] = true
			local ok, err = unretain_workflow_job(conn, id)
			if ok ~= true then return nil, err end
		end
	end
	for id in pairs(retained.ingest or {}) do
		local ok, err = unretain(conn, topics.workflow_artifact_ingest(id))
		if ok ~= true then return nil, err or 'artifact ingest workflow unretain failed' end
		retained.ingest[id] = nil
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
	local ok, err = publish_snapshot(conn, topics.update_summary(), projection.service_summary, snapshot)
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
		for id in pairs(retained.jobs) do
			bus_cleanup.unretain(conn, topics.workflow_update_job(id))
			bus_cleanup.unretain(conn, topics.workflow_update_job_timeline(id))
			retained.jobs[id] = nil
		end
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
