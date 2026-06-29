-- services/update/job_repository.lua
-- Pure durable-job model helpers.  No Ops, no HAL, no bus.

local model = require 'services.update.model'
local M = {}

local TERMINAL = { succeeded=true, failed=true, cancelled=true, timed_out=true, superseded=true, discarded=true }

local function copy(v) return model.deep_copy(v) end
local function count(t) local n=0 for _ in pairs(t or {}) do n=n+1 end return n end

local function sorted_ids(jobs)
	local ids = {}
	for id in pairs(jobs or {}) do ids[#ids+1] = id end
	table.sort(ids, function(a, b)
		local ja, jb = jobs[a] or {}, jobs[b] or {}
		local ta = ja.created_seq or ja.created_mono or 0
		local tb = jb.created_seq or jb.created_mono or 0
		if ta == tb then return tostring(a) < tostring(b) end
		return ta < tb
	end)
	return ids
end

local function strip_runtime(job)
	local out = {}
	for k, v in pairs(job or {}) do
		if k ~= 'runtime' then out[k] = copy(v) end
	end
	return out
end

local function normalise_job(job)
	if type(job) ~= 'table' then return nil, 'job must be a table' end
	local id = job.job_id
	if type(id) ~= 'string' or id == '' then return nil, 'job_id required' end
	local component = job.component
	if type(component) ~= 'string' or component == '' then return nil, 'component required' end
	if component == 'mcu' and (type(job.expected_image_id) ~= 'string' or job.expected_image_id == '') then
		return nil, 'expected_image_id_required'
	end

	if job.phase ~= nil or job.stage ~= nil then return nil, 'job lifecycle must use state, not phase or stage' end

	local out = strip_runtime(job)
	out.job_id = id
	out.component = component
	out.state = out.state or 'created'
	out.phase = nil
	out.stage = nil
	out.created_seq = out.created_seq or 0
	out.updated_seq = out.updated_seq or out.created_seq or 0
	out.history = type(out.history) == 'table' and out.history or {}
	return out, nil
end

function M.new_state(initial)
	local jobs = {}
	for id, job in pairs((initial and initial.jobs) or {}) do
		local normal, err = normalise_job(job)
		if not normal then return nil, err end
		jobs[id] = normal
	end
	return { jobs = jobs, order = sorted_ids(jobs), next_seq = initial and initial.next_seq or 1, dirty = {} }, nil
end

function M.is_terminal(state) return TERMINAL[state] == true end
function M.normalise_job(job) return normalise_job(job) end

function M.snapshot(repo)
	local by_id = {}
	for id, job in pairs(repo.jobs or {}) do by_id[id] = strip_runtime(job) end
	return { count = count(by_id), order = copy(repo.order or sorted_ids(by_id)), by_id = by_id }
end

function M.list(repo)
	local out = {}
	for _, id in ipairs(repo.order or sorted_ids(repo.jobs)) do
		if repo.jobs[id] then out[#out+1] = strip_runtime(repo.jobs[id]) end
	end
	return out
end

function M.get(repo, job_id)
	local job = repo.jobs and repo.jobs[job_id]
	return job and strip_runtime(job) or nil
end

function M.upsert(repo, job)
	local normal, err = normalise_job(job)
	if not normal then return nil, err end
	local id = normal.job_id
	local existed = repo.jobs[id] ~= nil
	repo.jobs[id] = normal
	if not existed then repo.order[#repo.order+1] = id end
	repo.order = sorted_ids(repo.jobs)
	repo.dirty[id] = true
	return strip_runtime(normal), nil
end

function M.remove(repo, job_id)
	if not (repo.jobs and repo.jobs[job_id]) then return false, 'not_found' end
	repo.jobs[job_id] = nil
	repo.dirty[job_id] = true
	for i = #repo.order, 1, -1 do
		if repo.order[i] == job_id then table.remove(repo.order, i) end
	end
	return true, nil
end

function M.next_sequence(repo)
	local n = repo.next_seq or 1
	repo.next_seq = n + 1
	return n
end

function M.new_job(spec, opts)
	spec = spec or {}; opts = opts or {}
	local id = spec.job_id or opts.job_id
	if type(id) ~= 'string' or id == '' then return nil, 'job_id required' end
	local component = spec.component
	if type(component) ~= 'string' or component == '' then return nil, 'component required' end
	local expected_image_id = spec.expected_image_id
	if component == 'mcu' and (type(expected_image_id) ~= 'string' or expected_image_id == '') then
		return nil, 'expected_image_id_required'
	end
	local seq = opts.seq or 0
	return {
		job_id = id,
		component = component,
		expected_image_id = expected_image_id,
		state = 'created',
		next_step = 'start',
		generation = opts.generation,
		artifact = copy(spec.artifact or spec.artifact_ref),
		artifact_ref = spec.artifact_ref,
		metadata = copy(spec.metadata or {}),
		created_seq = seq,
		updated_seq = seq,
		history = {{ seq = seq, state = 'created', reason = opts.reason or 'create_job' }},
	}, nil
end

local function bump(job, seq, reason)
	job.updated_seq = seq or ((job.updated_seq or 0) + 1)
	job.history = type(job.history) == 'table' and job.history or {}
	job.history[#job.history+1] = { seq = job.updated_seq, state = job.state, reason = reason }
end

function M.patch(job, patch, opts)
	if type(job) ~= 'table' then return nil, 'job required' end
	patch = patch or {}; opts = opts or {}
	if patch.phase ~= nil or patch.stage ~= nil then return nil, 'job lifecycle must use state, not phase or stage' end
	for k, v in pairs(patch) do
		job[k] = copy(v)
	end
	bump(job, opts.seq, opts.reason or patch.reason or 'patch')
	return strip_runtime(job), nil
end

function M.mark_staging(job, opts)
	return M.patch(job, { state = 'staging', next_step = nil, error = nil }, opts)
end

function M.mark_awaiting_commit(job, result, opts)
	return M.patch(job, { state = 'awaiting_commit', next_step = 'commit', stage_result = copy(result), error = nil }, opts)
end

function M.mark_committing(job, opts)
	return M.patch(job, { state = 'committing', next_step = nil, error = nil }, opts)
end

function M.mark_awaiting_return(job, result, opts)
	return M.patch(job, { state = 'awaiting_return', next_step = 'reconcile', commit_result = copy(result), error = nil }, opts)
end

function M.mark_terminal(job, state, reason, result, opts)
	state = state or 'failed'
	return M.patch(job, { state = state, next_step = nil, error = reason, result = copy(result) }, opts)
end

function M.public_job(job) return strip_runtime(job) end
M.TERMINAL = TERMINAL
return M
