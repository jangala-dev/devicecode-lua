-- services/update/job_repository.lua
-- Pure durable-job model helpers.  No Ops, no HAL, no bus.
--
-- The repository is intentionally compact.  Update jobs are operational state,
-- not an audit archive: public/durable forms retain the single current or last
-- job with only the fields needed to continue operation, render UI state, and
-- emit coarse telemetry.

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
		local ta = ja.updated_seq or ja.created_seq or ja.created_mono or 0
		local tb = jb.updated_seq or jb.created_seq or jb.created_mono or 0
		if ta == tb then return tostring(a) < tostring(b) end
		return ta < tb
	end)
	return ids
end

local function first_table(...)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if type(v) == 'table' then return v end
	end
	return nil
end

local function artifact_ref_of(job)
	if type(job) ~= 'table' then return nil end
	local art = first_table(job.artifact, job.artifact_snapshot, job.artifact_meta)
	return job.artifact_ref
		or job.ref
		or (art and (art.artifact_ref or art.ref or art.id))
end

local function compact_transfer(job)
	if type(job) ~= 'table' then return nil end
	local stage = type(job.stage_result) == 'table' and job.stage_result or nil
	local reply = stage and type(stage.reply) == 'table' and stage.reply or nil
	local inner = reply and (type(reply.transfer) == 'table' and reply.transfer or reply) or nil
	local result = inner and type(inner.result) == 'table' and inner.result or nil
	local out = {}
	local function absorb(src)
		if type(src) ~= 'table' then return end
		for _, key in ipairs({ 'xfer_id', 'request_id', 'link_id', 'target', 'digest_alg', 'digest', 'size', 'sent_bytes', 'retransmits' }) do
			if out[key] == nil and src[key] ~= nil then out[key] = src[key] end
		end
	end
	absorb(type(job.transfer) == 'table' and job.transfer or nil)
	absorb(stage and type(stage.transfer) == 'table' and stage.transfer or nil)
	absorb(result)
	absorb(inner)
	return next(out) ~= nil and out or nil
end

local function compact_stage_result(stage, job)
	if type(stage) ~= 'table' then return nil end
	local pre = type(stage.preflight) == 'table' and stage.preflight or {}
	local out = {
		staged = stage.staged == true or nil,
		component = stage.component or pre.component or (job and job.component),
		expected_image_id = stage.expected_image_id or pre.expected_image_id or (job and job.expected_image_id),
		transfer = compact_transfer({ stage_result = stage }),
	}
	local preflight = {
		artifact_ref = pre.artifact_ref or pre.ref,
		format = pre.format,
		image_id = pre.image_id,
		expected_image_id = pre.expected_image_id,
		size = pre.size,
		digest_alg = pre.digest_alg,
		digest = pre.digest,
		payload_sha256 = pre.payload_sha256,
	}
	if next(preflight) ~= nil then out.preflight = preflight end
	return next(out) ~= nil and out or nil
end

local function compact_pre_commit(pre)
	if type(pre) ~= 'table' then return nil end
	local out = {
		component = pre.component,
		expected_image_id = pre.expected_image_id,
		pre_commit_image_id = pre.pre_commit_image_id,
		pre_commit_boot_id = pre.pre_commit_boot_id,
		transfer = type(pre.transfer) == 'table' and copy(pre.transfer) or nil,
	}
	return next(out) ~= nil and out or nil
end

local function compact_commit_attempt(attempt)
	if type(attempt) ~= 'table' then return nil end
	local out = {
		token = attempt.token,
		policy = attempt.policy or attempt.commit_policy,
		active_token = attempt.active_token,
		generation = attempt.generation,
		acceptance = attempt.acceptance,
		accepted = attempt.accepted,
		started_seq = attempt.started_seq,
		accepted_seq = attempt.accepted_seq,
		failed_seq = attempt.failed_seq,
		error = attempt.error,
		pre_commit = compact_pre_commit(attempt.pre_commit),
	}
	return next(out) ~= nil and out or nil
end

local function compact_result(result)
	if type(result) ~= 'table' then return result end
	local out = {
		tag = result.tag,
		ok = result.ok,
		reason = result.reason,
		error = result.error,
		state = result.state and type(result.state) ~= 'table' and result.state or nil,
		expected_image_id = result.expected_image_id,
		image_id = result.image_id,
		commit_token = result.commit_token,
		commit_policy = result.commit_policy,
		previous_state = result.previous_state,
		restart_attempts = result.restart_attempts,
		restart_max = result.restart_max,
	}
	return next(out) ~= nil and out or nil
end

local function compact_active_intent(intent)
	if type(intent) ~= 'table' then return nil end
	local out = {
		token = intent.token,
		phase = intent.phase,
		generation = intent.generation,
		request_id = intent.request_id,
		state = intent.state,
		reason = intent.reason,
		restart_count = intent.restart_count,
		attempt = intent.attempt,
		restart_max = intent.restart_max,
		commit_token = intent.commit_token,
		commit_policy = intent.commit_policy,
	}
	return next(out) ~= nil and out or nil
end

local function compact_adoption(adoption)
	if type(adoption) ~= 'table' then return nil end
	local out = {
		action = adoption.action,
		reason = adoption.reason,
		from_state = adoption.from_state,
		restart_attempts = adoption.restart_attempts,
		attempt = adoption.attempt,
		restart_max = adoption.restart_max,
		seq = adoption.seq,
	}
	return next(out) ~= nil and out or nil
end

local function compact_policy(policy)
	if type(policy) ~= 'table' then return nil end
	local out = {}
	local keys = {
		'job_id', 'create_if', 'start', 'commit', 'reconcile', 'supersede',
		'attempt', 'max_attempts',
	}
	for _, key in ipairs(keys) do
		out[key] = policy[key]
	end
	return next(out) ~= nil and out or nil
end

local function last_event_from(job)
	if type(job) ~= 'table' then return nil end
	if type(job.last_event) == 'table' then return copy(job.last_event) end
	local hist = type(job.history) == 'table' and job.history or nil
	local last = hist and hist[#hist] or nil
	if type(last) ~= 'table' then return nil end
	return { seq = last.seq, state = last.state, reason = last.reason }
end

local function is_terminal_state(state)
	return TERMINAL[state] == true
end

function M.compact_job(job)
	if type(job) ~= 'table' then return nil end
	local state = job.state or 'created'
	local terminal = is_terminal_state(state)
	local out = {
		schema = 'devicecode.update.job/2',
		job_id = job.job_id,
		component = job.component,
		state = state,
		artifact_ref = artifact_ref_of(job),
		expected_image_id = job.expected_image_id,
		created_seq = job.created_seq or 0,
		updated_seq = job.updated_seq or job.created_seq or 0,
		error = job.error,
		result = compact_result(job.result),
		transfer = compact_transfer(job),
		last_event = last_event_from(job),
	}
	if not terminal then
		out.next_step = job.next_step
		out.generation = job.generation
	end

	if terminal then
		-- Keep the compact commit attempt for compatibility with existing update
		-- reconciliation/status consumers.  This is small and operationally meaningful;
		-- the large stage/transfer reply remains collapsed into transfer/result fields.
		out.commit_attempt = compact_commit_attempt(job.commit_attempt)
	end
	if terminal and state == 'failed' then
		local adoption = compact_adoption(job.adoption)
		if adoption and adoption.action == 'failed_restart_limit' then out.adoption = adoption end
	end

	if not terminal then
		local metadata = type(job.metadata) == 'table' and copy(job.metadata) or nil
		-- Metadata is operational input for component prepare/stage calls.  Keep it
		-- while a job can still be staged or committed, but terminal compaction
		-- deliberately drops it.
		out.metadata = metadata and next(metadata) ~= nil and metadata or nil
		out.ingest_id = job.ingest_id or (metadata and metadata.ingest_id or nil)
		out.attempt = job.attempt
		out.active_token = job.active_token
		out.active_intent = compact_active_intent(job.active_intent)
		out.active = compact_active_intent(job.active)
		out.adoption = compact_adoption(job.adoption)
		out.stage_result = compact_stage_result(job.stage_result, job)
		out.commit_attempt = compact_commit_attempt(job.commit_attempt)
		out.commit_result = compact_result(job.commit_result)
		out.policy = compact_policy(job.policy)
		if out.active == nil and out.active_intent ~= nil then out.active = copy(out.active_intent) end
		-- Preserve the one runtime field that can affect admission while a save is pending.
		if type(job.runtime) == 'table' and job.runtime.persistence_pending then
			out.runtime = { persistence_pending = true }
		end
	end

	return out
end

local function strip_runtime(job)
	return M.compact_job(job)
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

	local out = M.compact_job(job)
	out.job_id = id
	out.component = component
	out.state = out.state or 'created'
	out.phase = nil
	out.stage = nil
	out.created_seq = out.created_seq or 0
	out.updated_seq = out.updated_seq or out.created_seq or 0
	return out, nil
end

function M.new_state(initial)
	local jobs = {}
	for id, job in pairs((initial and initial.jobs) or {}) do
		local normal, err = normalise_job(job)
		if not normal then
			-- Legacy stores may contain malformed records from development builds. Keep a
			-- minimal tombstone long enough for the startup scrub to delete it, rather
			-- than failing the service before it can reclaim storage.
			jobs[id] = {
				schema = 'devicecode.update.job/2',
				job_id = type(job) == 'table' and job.job_id or tostring(id),
				component = type(job) == 'table' and job.component or 'unknown',
				state = 'invalid_legacy',
				error = err or 'invalid_legacy_job',
				created_seq = type(job) == 'table' and tonumber(job.created_seq) or 0,
				updated_seq = type(job) == 'table' and tonumber(job.updated_seq) or 0,
			}
		else
			jobs[id] = normal
		end
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

function M.replace(repo, job_id, job)
	local normal, err = normalise_job(job)
	if not normal then return nil, err end
	repo.jobs[job_id or normal.job_id] = normal
	repo.order = sorted_ids(repo.jobs)
	repo.dirty[job_id or normal.job_id] = true
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
	return M.compact_job({
		job_id = id,
		component = component,
		expected_image_id = expected_image_id,
		state = 'created',
		next_step = 'start',
		generation = opts.generation,
		artifact = copy(spec.artifact or spec.artifact_ref),
		artifact_ref = spec.artifact_ref,
		attempt = spec.attempt,
		metadata = copy(spec.metadata or {}),
		policy = copy(spec.policy),
		created_seq = seq,
		updated_seq = seq,
		last_event = { seq = seq, state = 'created', reason = opts.reason or 'create_job' },
	}), nil
end

local function bump(job, seq, reason)
	job.updated_seq = seq or ((job.updated_seq or 0) + 1)
	job.last_event = { seq = job.updated_seq, state = job.state, reason = reason }
	job.history = nil
end

function M.patch(job, patch, opts)
	if type(job) ~= 'table' then return nil, 'job required' end
	patch = patch or {}; opts = opts or {}
	if patch.phase ~= nil or patch.stage ~= nil then return nil, 'job lifecycle must use state, not phase or stage' end
	for k, v in pairs(patch) do
		job[k] = copy(v)
	end
	bump(job, opts.seq, opts.reason or patch.reason or 'patch')
	local compact = M.compact_job(job)
	for k in pairs(job) do job[k] = nil end
	for k, v in pairs(compact or {}) do job[k] = v end
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
