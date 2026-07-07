-- services/update/projection.lua
--
-- Pure conversion from internal update snapshots to retained/public payloads.
-- Retained update state is intentionally compact: it describes the current
-- appliance update state, not an audit archive of all historic jobs.

local model = require 'services.update.model'
local repo  = require 'services.update.job_repository'

local M = {}

local function copy(v)
	return model.deep_copy(v)
end

local function jobs_by_id(snapshot)
	local jobs = snapshot and snapshot.jobs or nil
	local src = type(jobs) == 'table' and type(jobs.by_id) == 'table' and jobs.by_id or {}
	local out = {}
	for id, job in pairs(src) do
		if type(job) == 'table' then
			if job.job_id == nil and type(id) == 'string' then
				-- Some recovery paths and legacy compact records may be keyed by durable
				-- job id while carrying a minimal payload. Public component/update
				-- projections must still expose the durable identity expected by UI and
				-- integration callers. Do this at the projection boundary rather than
				-- re-inflating retained/durable job records.
				local copy_job = copy(job)
				copy_job.job_id = id
				out[id] = copy_job
			else
				out[id] = job
			end
		end
	end
	return out
end

local function newest_job(snapshot, component)
	local best
	for _, job in pairs(jobs_by_id(snapshot)) do
		if type(job) == 'table' and (component == nil or job.component == component) then
			local bt = best and (best.updated_seq or best.created_seq or 0) or -1
			local jt = job.updated_seq or job.created_seq or 0
			if best == nil or jt > bt then best = job end
		end
	end
	return best
end

local function dependency_summary(deps)
	local out = {}
	for k, dep in pairs(type(deps) == 'table' and deps or {}) do
		if type(dep) == 'table' then
			out[k] = {
				key = dep.key or k,
				class = dep.class,
				id = dep.id,
				available = dep.available == true,
				status = dep.status or dep.observed_status,
				required = dep.required == true,
				route_missing = dep.route_missing == true,
				updated_at = dep.updated_at,
			}
		end
	end
	return out
end

local function job_brief_fields(job)
	job = repo.public_job(job) or {}
	local result = type(job.result) == 'table' and job.result or nil
	return {
		job_id = job.job_id,
		component = job.component,
		state = job.state,
		next_step = job.next_step,
		error = job.error,
		expected_image_id = job.expected_image_id,
		artifact_ref = job.artifact_ref,
		created_seq = job.created_seq,
		updated_seq = job.updated_seq,
		commit_attempt = copy(job.commit_attempt),
		commit_result = copy(job.commit_result),
		result = result and {
			ok = result.ok,
			tag = result.tag,
			reason = result.reason,
			error = result.error,
		} or nil,
		last_event = copy(job.last_event),
	}
end

function M.job_brief(job)
	if type(job) ~= 'table' then return nil end
	return job_brief_fields(job)
end

local function action_set(job)
	local state = type(job) == 'table' and job.state or nil
	return {
		commit = state == 'awaiting_commit',
		discard = state == 'awaiting_commit' or state == 'created' or state == 'failed',
		retry = state == 'failed' or state == 'timed_out',
	}
end

function M.component_summary(component, snapshot)
	local job = newest_job(snapshot, component)
	local brief = M.job_brief(job)
	local active = type(job) == 'table' and not repo.is_terminal(job.state) or false
	local out = {
		schema = 'devicecode.update.component/1',
		kind = 'update.component',
		component = component,
		state = (brief and brief.state) or 'idle',
		ready = snapshot and snapshot.ready == true or nil,
		current_job = active and brief or nil,
		last_job = (not active) and brief or nil,
		actions = action_set(job),
	}
	if brief then
		-- Compatibility: existing UI/devhost callers treat state/update/component/<id>
		-- itself as the visible job record and read fields such as job_id and
		-- commit_attempt from the top level.  Keep that compact surface while avoiding
		-- the previous full job/history/stage_result payloads.
		out.job_id = brief.job_id
		out.expected_image_id = brief.expected_image_id
		out.artifact_ref = brief.artifact_ref
		out.next_step = brief.next_step
		out.error = brief.error
		out.created_seq = brief.created_seq
		out.updated_seq = brief.updated_seq
		out.commit_attempt = copy(brief.commit_attempt)
		out.commit_result = copy(brief.commit_result)
		out.result = copy(brief.result)
		out.last_event = copy(brief.last_event)
	end
	return out
end

local function component_ids(snapshot)
	local ids = {}
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
	for id in pairs(seen) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

function M.service_summary(snapshot)
	snapshot = snapshot or {}
	local latest = newest_job(snapshot)
	local latest_brief = M.job_brief(latest)
	local comps = {}
	for _, component in ipairs(component_ids(snapshot)) do
		comps[component] = M.component_summary(component, snapshot)
	end
	return {
		schema = 'devicecode.update.summary/1',
		service    = snapshot.service or 'update',
		state      = snapshot.state or 'unknown',
		ready      = snapshot.ready == true,
		reason     = snapshot.reason,
		generation = snapshot.generation,
		config     = snapshot.config and {
			rev = snapshot.config.rev,
			schema = snapshot.config.schema,
			service_id = snapshot.config.service_id,
			namespace = snapshot.config.namespace,
			component_count = snapshot.config.component_count,
			bundled_enabled = snapshot.config.bundled_enabled,
		} or nil,
		active     = snapshot.active and {
			generation = snapshot.active.generation,
			state = snapshot.active.state,
		} or nil,
		job = latest_brief and {
			present = true,
			job_id = latest_brief.job_id,
			component = latest_brief.component,
			state = latest_brief.state,
			next_step = latest_brief.next_step,
			expected_image_id = latest_brief.expected_image_id,
			updated_seq = latest_brief.updated_seq,
			result = latest_brief.result,
		} or { present = false },
		jobs = {
			count = latest_brief and 1 or 0,
			last = latest_brief,
		},
		components = comps,
		dependencies = dependency_summary(snapshot.dependencies),
		pending = copy(snapshot.pending),
		publisher  = snapshot.publisher and { state = snapshot.publisher.state } or nil,
	}
end

-- Backwards-compatible name for callers that still ask for service_state.
function M.service_state(snapshot)
	return M.service_summary(snapshot)
end

function M.capability(snapshot)
	snapshot = snapshot or {}
	return {
		kind       = 'update.service',
		service    = snapshot.service or 'update',
		generation = snapshot.generation,
		ready      = snapshot.ready == true,
		methods    = {
			'status',
			'list-jobs',
			'get-job',
			'create-job',
			'start-job',
			'commit-job',
			'cancel-job',
			'retry-job',
			'discard-job',
		},
	}
end

function M.jobs(snapshot)
	local list = {}
	for _, job in pairs(jobs_by_id(snapshot)) do
		local brief = M.job_brief(job)
		if brief then list[#list + 1] = brief end
	end
	table.sort(list, function(a, b)
		local ta = a.updated_seq or a.created_seq or 0
		local tb = b.updated_seq or b.created_seq or 0
		if ta == tb then return tostring(a.job_id) < tostring(b.job_id) end
		return ta < tb
	end)
	local by_id = {}
	local order = {}
	for _, job in ipairs(list) do
		order[#order + 1] = job.job_id
		by_id[job.job_id] = job
	end
	return { count = #list, order = order, by_id = by_id }
end

function M.job(job)
	return repo.public_job(job)
end

function M.job_timeline(job)
	job = repo.public_job(job) or {}
	local events = {}
	if type(job.last_event) == 'table' then
		events[1] = copy(job.last_event)
	end
	return {
		kind = 'update.job.timeline',
		job_id = job.job_id,
		component = job.component,
		state = job.state,
		updated_seq = job.updated_seq,
		events = events,
	}
end

function M.ingest(record)
	return copy(record)
end

function M.manager_status(snapshot)
	local summary = M.service_summary(snapshot)
	-- Manager RPC status keeps a compact jobs map briefly for older callers.
	-- Retained state/update/summary deliberately does not carry this map.
	summary.jobs = M.jobs(snapshot)
	return { ok = true, snapshot = summary }
end

return M
