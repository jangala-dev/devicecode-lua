-- services/update/job_runtime.lua
--
-- Service-owned durable job runtime.
--
-- This is the only owner of authoritative durable job state.  Callers submit
-- transition requests and receive completion values after the transition has
-- been durably applied.  Generations and active workers may observe snapshots
-- and request transitions; they must not mutate durable jobs or call the job
-- store directly.

local fibers      = require 'fibers'
local op          = require 'fibers.op'
local cond        = require 'fibers.cond'
local mailbox     = require 'fibers.mailbox'
local scoped_work = require 'devicecode.support.scoped_work'
local queue       = require 'devicecode.support.queue'

local model_mod     = require 'services.update.model'
local repo_mod      = require 'services.update.job_repository'
local active_policy = require 'services.update.active_policy'

local M = {}

local DEFAULT_QUEUE = 32

local Runtime = {}
Runtime.__index = Runtime

local function copy(v)
	return model_mod.deep_copy(v)
end

local function count_keys(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function new_id(prefix)
	local ok_uuid, uuid = pcall(require, 'uuid')
	if ok_uuid and uuid and type(uuid.new) == 'function' then
		return tostring(uuid.new())
	end
	return (prefix or 'job') .. '-' .. tostring(math.floor((fibers.now() or 0) * 1000000))
end

local TRANSITION_STATES = {
	proposed  = true,
	admitted  = true,
	persisting = true,
	persisted = true,
	rejected  = true,
	failed    = true,
	cancelled = true,
}

local function transition_public(cmd)
	cmd = type(cmd) == 'table' and cmd or {}
	return {
		transition = cmd.kind,
		job_id = cmd.job_id or (cmd.payload and cmd.payload.job_id),
		generation = cmd.generation,
		phase = cmd.phase,
		token = cmd.token,
		reason = cmd.reason,
	}
end

local function transition_record(req, state, details)
	details = details or {}
	local cmd = req and req.cmd or {}
	local base = transition_public(cmd)
	base.transition_id = req and req.id or details.transition_id
	base.state = state or 'proposed'
	base.status = state or 'proposed'
	base.sequence = details.sequence
	base.started = details.started
	base.finished = details.finished
	base.error = details.error
	base.plan_kind = details.plan_kind
	if state == 'admitted'
		or state == 'persisting'
		or state == 'persisted'
		or details.admitted == true
		or (state == 'failed' and details.plan_kind ~= nil)
	then
		base.admitted = true
	end
	return base
end

local function copy_transition_record(rec)
	return copy(rec or {})
end

local function transition_snapshot(self)
	local by_id = {}
	local order = {}
	for _, id in ipairs(self._transition_order or {}) do
		local rec = self._transitions and self._transitions[id]
		if rec then
			order[#order + 1] = id
			by_id[id] = copy_transition_record(rec)
		end
	end
	return { count = #order, order = order, by_id = by_id }
end

local function transition_set(self, req, state, details)
	if not TRANSITION_STATES[state] then
		error('invalid transition lifecycle state: ' .. tostring(state), 2)
	end

	details = details or {}
	self._transitions = self._transitions or {}
	self._transition_order = self._transition_order or {}

	local id = assert(req and req.id, 'transition request missing id')
	local rec = transition_record(req, state, details)
	local existing = self._transitions[id]

	if existing == nil then
		self._transitions[id] = rec
		self._transition_order[#self._transition_order + 1] = id
	else
		-- Current lifecycle fields must describe the current state, not a
		-- breadcrumb trail. In particular, a rejected-before-admission request must
		-- not retain admitted=true from an earlier provisional record.
		for k in pairs(existing) do
			existing[k] = nil
		end
		for k, v in pairs(rec) do
			existing[k] = v
		end
		rec = existing
	end

	if state == 'rejected' or state == 'failed' or state == 'persisted' or state == 'cancelled' then
		rec.finished = true
	end

	return rec
end

local function transition_outcome_from_record(rec, value)
	local out = copy(value or {})
	out.transition_id = rec.transition_id
	out.transition = out.transition or rec.transition
	out.job_id = out.job_id or rec.job_id
	out.generation = out.generation or rec.generation
	out.phase = out.phase or rec.phase
	out.token = out.token or rec.token
	out.transition_state = rec.state
	out.lifecycle = rec.state
	return out
end

local function load_jobs(params)
	params = params or {}
	local store = params.store
	local loaded, err

	if store and type(store.load_all_op) == 'function' then
		loaded, err = fibers.perform(store:load_all_op())
		if not loaded then return nil, err or 'job_load_failed' end
	else
		loaded = params.initial_jobs or { jobs = {}, order = {} }
	end

	local jobs, jerr = repo_mod.new_state(loaded)
	if not jobs then return nil, jerr end
	return jobs, nil
end

local function public_job(job)
	return job and repo_mod.public_job(job) or nil
end

local function adoption_empty()
	return {
		awaiting_commit = {},
		awaiting_return = {},
		active_intent = {},
		failed = {},
		decisions = {},
		diagnostics = {},
	}
end


local function runtime_snapshot(self_or_jobs, ready, adoption)
	local jobs = self_or_jobs
	local transitions
	if type(self_or_jobs) == 'table' and self_or_jobs._jobs ~= nil then
		jobs = self_or_jobs._jobs
		transitions = transition_snapshot(self_or_jobs)
	end
	return {
		ready = not not ready,
		jobs = repo_mod.snapshot(jobs),
		adoption = copy(adoption or {}),
		transitions = transitions,
		count = count_keys(jobs and jobs.jobs or {}),
	}
end

local function refresh_model(self)
	if self and self._model then
		self._model:set_snapshot(runtime_snapshot(self, self._ready, self._adoption))
	end
end

local function resolve_cell(cell, value, err)
	if not cell or cell.done then return false end
	cell.done = true
	cell.value = value
	cell.err = err
	cell.cond:signal()
	return true
end

local function transition_result_op(cell)
	return op.guard(function ()
		if cell.done then
			return op.always(cell.value, cell.err)
		end

		return cell.cond:wait_op():wrap(function ()
			return cell.value, cell.err
		end)
	end)
end

local function make_cell()
	return {
		cond = cond.new(),
		done = false,
		value = nil,
		err = nil,
	}
end

local TransitionHandle = {}
TransitionHandle.__index = TransitionHandle

function TransitionHandle:transition_id()
	return self._id
end

function TransitionHandle:command()
	return copy(self._cmd)
end

function TransitionHandle:outcome_op()
	return transition_result_op(self._cell)
end

function TransitionHandle:outcome()
	return fibers.perform(self:outcome_op())
end

local function new_transition_handle(req)
	return setmetatable({
		_id = req.id,
		_cmd = copy(req.cmd),
		_cell = req.cell,
	}, TransitionHandle)
end

local function store_save_op(store, job)
	if not store or type(store.save_job_op) ~= 'function' then
		return op.always(true, nil)
	end
	return store:save_job_op(job)
end

local function store_delete_op(store, job_id)
	if not store or type(store.delete_job_op) ~= 'function' then
		return op.always(true, nil)
	end
	return store:delete_job_op(job_id)
end

local function sorted_job_ids(jobs)
	local ids = {}
	for id in pairs((jobs and jobs.jobs) or {}) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local function next_adoption_seq(jobs)
	local seq = jobs.next_seq or 1
	jobs.next_seq = seq + 1
	return seq
end

local function save_adopted_job(self, jobs, job)
	local saved, uerr = repo_mod.upsert(jobs, job)
	if not saved then return nil, uerr end
	local ok, serr = fibers.perform(store_save_op(self._store, public_job(job)))
	if ok ~= true then return nil, serr or 'adoption_save_failed' end
	return true, nil
end

local function adopt_restart_jobs(self, jobs)
	local adoption = adoption_empty()

	for _, id in ipairs(sorted_job_ids(jobs)) do
		local current = jobs.jobs[id]
		local state = current and current.state
		if state == 'awaiting_commit' then
			local job = copy(current)
			local seq = next_adoption_seq(jobs)
			repo_mod.patch(job, {
				adoption = {
					action = 'kept_committable',
					reason = 'restart_awaiting_commit',
					seq = seq,
				},
			}, { seq = seq, reason = 'restart_adoption_awaiting_commit' })
			local ok, err = save_adopted_job(self, jobs, job)
			if ok ~= true then return nil, err end
			local pub = public_job(job)
			adoption.awaiting_commit[#adoption.awaiting_commit + 1] = pub
			adoption.decisions[#adoption.decisions + 1] = {
				job_id = id,
				from_state = state,
				action = 'kept_committable',
				job = pub,
			}
		elseif state == 'awaiting_return' then
			local job = copy(current)
			local seq = next_adoption_seq(jobs)
			repo_mod.patch(job, {
				adoption = {
					action = 'reconcile_required',
					reason = 'restart_awaiting_return',
					seq = seq,
				},
			}, { seq = seq, reason = 'restart_adoption_awaiting_return' })
			local ok, err = save_adopted_job(self, jobs, job)
			if ok ~= true then return nil, err end
			local pub = public_job(job)
			adoption.awaiting_return[#adoption.awaiting_return + 1] = pub
			adoption.decisions[#adoption.decisions + 1] = {
				job_id = id,
				from_state = state,
				action = 'reconcile_required',
				job = pub,
			}
		elseif state == 'staging' or state == 'committing' then
			local has_intent = current.active_token ~= nil or type(current.active_intent) == 'table'
			local job = copy(current)
			local seq = next_adoption_seq(jobs)
			local intent = type(job.active_intent) == 'table' and job.active_intent or nil
			local phase = intent and intent.phase or nil
			local attempt = type(job.commit_attempt) == 'table' and job.commit_attempt or nil
			local commit_policy = attempt and (attempt.policy or attempt.commit_policy) or (intent and intent.commit_policy)

			if has_intent and state == 'committing' and phase == 'commit' and commit_policy == 'no_duplicate' then
				repo_mod.mark_awaiting_return(job, {
					tag = 'commit_uncertain_no_duplicate',
					commit_token = attempt and attempt.token or intent.commit_token or job.active_token,
					commit_policy = commit_policy,
				}, { seq = seq, reason = 'restart_commit_no_duplicate_reconcile' })
				job.adoption = {
					action = 'reconcile_required',
					reason = 'restart_commit_no_duplicate',
					from_state = state,
					seq = seq,
				}
				if attempt then
					job.commit_attempt = copy(attempt)
					job.commit_attempt.acceptance = job.commit_attempt.acceptance or 'unknown'
					job.commit_attempt.adoption = 'no_duplicate_reconcile'
				end
				job.active = nil
				job.active_token = nil
				job.active_intent = nil
				local ok, err = save_adopted_job(self, jobs, job)
				if ok ~= true then return nil, err end
				local pub = public_job(job)
				adoption.awaiting_return[#adoption.awaiting_return + 1] = pub
				adoption.decisions[#adoption.decisions + 1] = {
					job_id = id,
					from_state = state,
					action = 'reconcile_required',
					reason = 'restart_commit_no_duplicate',
					job = pub,
				}
			elseif has_intent and (state ~= 'committing' or phase ~= 'commit' or commit_policy == 'idempotent_by_token') then
				job.active_intent = intent
				job.active_intent.state = 'adopted'
				job.active_intent.reason = 'restart_active_intent'
				job.active = copy(job.active_intent)
				repo_mod.patch(job, {
					adoption = {
						action = 'resume_active_intent',
						reason = 'restart_active_intent',
						from_state = state,
						seq = seq,
					},
				}, { seq = seq, reason = 'restart_adoption_active_intent' })
				local ok, err = save_adopted_job(self, jobs, job)
				if ok ~= true then return nil, err end
				local pub = public_job(job)
				adoption.active_intent[#adoption.active_intent + 1] = pub
				adoption.decisions[#adoption.decisions + 1] = {
					job_id = id,
					from_state = state,
					action = 'resume_active_intent',
					job = pub,
				}
			else
				local reason = (state == 'committing' and phase == 'commit') and 'restart_commit_policy_missing' or ('restart_interrupted_' .. tostring(state))
				repo_mod.mark_terminal(job, 'failed', reason, {
					previous_state = state,
				}, { seq = seq, reason = 'restart_adoption_failed_' .. tostring(reason) })
				job.adoption = {
					action = 'failed_impossible_state',
					reason = reason,
					from_state = state,
					seq = seq,
				}
				job.active = nil
				job.active_token = nil
				job.active_intent = nil
				local ok, err = save_adopted_job(self, jobs, job)
				if ok ~= true then return nil, err end
				local pub = public_job(job)
				adoption.failed[#adoption.failed + 1] = pub
				adoption.decisions[#adoption.decisions + 1] = {
					job_id = id,
					from_state = state,
					action = 'failed_impossible_state',
					reason = job.error,
					job = pub,
				}
				adoption.diagnostics[#adoption.diagnostics + 1] = {
					job_id = id,
					message = 'job was interrupted during ' .. tostring(state) .. ' and was marked failed',
				}
			end
		end
	end

	return adoption, nil
end

local function next_sequence_value(jobs)
	return jobs and (jobs.next_seq or 1) or 1
end

local function validate_generation(cmd, current)
	-- Generation-scoped admissions must be checked against the service-owned
	-- current generation at the point where job_runtime is about to admit them.
	-- Already-admitted durable work is not revalidated later, and active-result
	-- application is validated by durable active token rather than by the current
	-- generation, because accepted active work may outlive generation replacement.
	if cmd.generation ~= nil and current ~= nil and cmd.generation ~= current then
		return nil, 'stale_generation'
	end
	return true, nil
end

local GENERATION_VALIDATED_TRANSITIONS = {
	create_job    = true,
	start_job     = true,
	mark_starting = true,
	patch_job     = true,
	mark_job      = true,
	discard_job   = true,
	delete_job    = true,
}

local function active_token_for(cmd, job, phase, seq)
	if cmd.token ~= nil then return cmd.token end
	return table.concat({
		tostring(cmd.generation or job.generation or 0),
		tostring(job.job_id),
		tostring(phase or 'stage'),
		tostring(seq or 0),
	}, ':')
end

local COMMIT_POLICIES = {
	idempotent_by_token = true,
	no_duplicate = true,
}

local function normalise_commit_policy(policy)
	if type(policy) == 'table' then policy = policy.policy end
	if COMMIT_POLICIES[policy] then return policy end
	return nil, 'commit_policy_required'
end

local function commit_token_for(cmd, job)
	return cmd.commit_token
		or (type(job.commit_attempt) == 'table' and job.commit_attempt.token)
		or (type(job.active_intent) == 'table' and job.active_intent.commit_token)
		or job.active_token
		or cmd.token
end

local function durable_active_owner(jobs)
	for id, job in pairs((jobs and jobs.jobs) or {}) do
		if job.active_token ~= nil or type(job.active_intent) == 'table' then
			return id, job
		end
	end
	return nil, nil
end

local function compute_create(self, cmd)
	local payload = copy(cmd.payload or cmd.job or {})
	payload.job_id = payload.job_id or cmd.job_id or new_id('job')

	local job, err = repo_mod.new_job(payload, {
		job_id = payload.job_id,
		generation = cmd.generation,
		seq = next_sequence_value(self._jobs),
		reason = cmd.reason or 'create_job',
	})
	if not job then return nil, err end

	if self._jobs.jobs[job.job_id] ~= nil then
		return nil, 'job_exists'
	end

	return {
		kind = 'save_job',
		transition = cmd.kind,
		job = job,
		job_id = job.job_id,
		next_seq = next_sequence_value(self._jobs) + 1,
		public_result = {
			tag = 'job_created',
			method = 'create_job',
			job_id = job.job_id,
			job = public_job(job),
			auto_start = payload.auto_start == true,
		},
	}, nil
end

local function compute_start(self, cmd)
	local current = cmd.job_id and self._jobs.jobs[cmd.job_id] or nil
	if not current then return nil, 'not_found' end

	local active_owner = durable_active_owner(self._jobs)
	if active_owner ~= nil then
		return nil, 'slot_busy'
	end

	local phase = cmd.phase or active_policy.phase_for(current, cmd.payload)
	local ok_phase, phase_err = active_policy.can_start_phase(current, phase)
	if ok_phase ~= true then return nil, phase_err end

	local seq = next_sequence_value(self._jobs)
	local job = active_policy.mark_starting(copy(current), phase, seq)
	local token = active_token_for(cmd, job, phase, seq)

	job.active_token = token
	job.active_intent = {
		token = token,
		phase = phase,
		generation = cmd.generation,
		request_id = cmd.request_id,
		state = 'pending',
		reason = cmd.reason or (phase == 'commit' and 'start_commit' or 'start_stage'),
	}
	-- Transitional public field for existing projections/tests.  Ownership is the
	-- durable active_intent above.
	job.active = copy(job.active_intent)

	return {
		kind = 'save_job',
		transition = cmd.kind,
		job = job,
		job_id = job.job_id,
		phase = phase,
		token = token,
		next_seq = seq + 1,
		public_result = {
			tag = 'job_started',
			method = phase == 'commit' and 'commit_job' or 'start_job',
			job_id = job.job_id,
			phase = phase,
			token = token,
			job = public_job(job),
		},
	}, nil
end

local function compute_begin_commit_attempt(self, cmd)
	local current = cmd.job_id and self._jobs.jobs[cmd.job_id] or nil
	if not current then return nil, 'not_found' end
	if current.state ~= 'committing' then return nil, 'job_not_committing' end

	local expected_token = current.active_token or (current.active and current.active.token)
	if expected_token == nil then return nil, 'not_active' end
	if cmd.token ~= nil and cmd.token ~= expected_token then return nil, 'stale_active_token' end

	local policy, perr = normalise_commit_policy(cmd.commit_policy or cmd.policy)
	if not policy then return nil, perr end

	local token = commit_token_for(cmd, current)
	if token == nil or token == '' then return nil, 'commit_token_required' end

	local existing = type(current.commit_attempt) == 'table' and current.commit_attempt or nil
	if existing ~= nil then
		if existing.token ~= nil and existing.token ~= token then
			return nil, 'commit_token_mismatch'
		end
		local existing_policy = existing.policy or existing.commit_policy
		if existing_policy ~= nil and existing_policy ~= policy then
			return nil, 'commit_policy_mismatch'
		end
	end

	local seq = next_sequence_value(self._jobs)
	local job = copy(current)
	job.commit_attempt = copy(existing or {})
	job.commit_attempt.token = token
	job.commit_attempt.policy = policy
	job.commit_attempt.active_token = expected_token
	job.commit_attempt.generation = cmd.generation or job.generation
	job.commit_attempt.acceptance = job.commit_attempt.acceptance or 'unknown'
	job.commit_attempt.started_seq = job.commit_attempt.started_seq or seq
	job.commit_attempt.reason = cmd.reason or 'begin_commit_attempt'
	if cmd.pre_commit ~= nil then
		job.commit_attempt.pre_commit = copy(cmd.pre_commit)
	end

	job.active_intent = type(job.active_intent) == 'table' and copy(job.active_intent) or { token = expected_token, phase = 'commit' }
	job.active_intent.commit_token = token
	job.active_intent.commit_policy = policy
	job.active_intent.state = job.active_intent.state or 'running'
	job.active = copy(job.active_intent)

	repo_mod.patch(job, {
		commit_attempt = job.commit_attempt,
		active_intent = job.active_intent,
		active = job.active,
	}, { seq = seq, reason = cmd.reason or 'begin_commit_attempt' })

	return {
		kind = 'save_job',
		transition = cmd.kind,
		job = job,
		job_id = job.job_id,
		phase = 'commit',
		token = expected_token,
		commit_token = token,
		commit_policy = policy,
		next_seq = seq + 1,
		public_result = {
			tag = 'commit_attempt_begun',
			job_id = job.job_id,
			phase = 'commit',
			token = expected_token,
			commit_token = token,
			commit_policy = policy,
			job = public_job(job),
		},
	}, nil
end


local function compute_commit_accepted(self, cmd)
	local current = cmd.job_id and self._jobs.jobs[cmd.job_id] or nil
	if not current then return nil, 'not_found' end

	local policy, perr = normalise_commit_policy(cmd.commit_policy or cmd.policy)
	if not policy then return nil, perr end

	local token = commit_token_for(cmd, current)
	if token == nil or token == '' then return nil, 'commit_token_required' end

	local attempt = type(current.commit_attempt) == 'table' and current.commit_attempt or nil
	local expected_active_token = current.active_token or (current.active_intent and current.active_intent.token) or (attempt and attempt.active_token)
	if cmd.token ~= nil and expected_active_token ~= nil and cmd.token ~= expected_active_token then
		return nil, 'stale_active_token'
	end

	if current.state == 'awaiting_return' then
		if attempt ~= nil then
			if attempt.token ~= nil and attempt.token ~= token then return nil, 'commit_token_mismatch' end
			local existing_policy = attempt.policy or attempt.commit_policy
			if existing_policy ~= nil and existing_policy ~= policy then return nil, 'commit_policy_mismatch' end
		end
		local job = copy(current)
		job.commit_attempt = copy(attempt or {})
		job.commit_attempt.token = token
		job.commit_attempt.policy = policy
		job.commit_attempt.active_token = job.commit_attempt.active_token or expected_active_token or cmd.token
		job.commit_attempt.acceptance = 'accepted'
		job.commit_attempt.accepted = true
		job.commit_attempt.accepted_result = copy(cmd.accepted or cmd.result or {})
		job.commit_attempt.accepted_seq = job.commit_attempt.accepted_seq or next_sequence_value(self._jobs)
		repo_mod.patch(job, {
			commit_attempt = job.commit_attempt,
		}, { seq = next_sequence_value(self._jobs), reason = cmd.reason or 'commit_accepted_idempotent' })
		return {
			kind = 'save_job',
			transition = cmd.kind,
			job = job,
			job_id = job.job_id,
			phase = 'commit',
			token = cmd.token or expected_active_token,
			commit_token = token,
			commit_policy = policy,
			next_seq = next_sequence_value(self._jobs) + 1,
			public_result = {
				tag = 'commit_accepted',
				job_id = job.job_id,
				phase = 'commit',
				token = cmd.token or expected_active_token,
				commit_token = token,
				commit_policy = policy,
				job = public_job(job),
			},
		}, nil
	end

	if current.state ~= 'committing' then return nil, 'job_not_committing' end
	if expected_active_token == nil then return nil, 'not_active' end

	if attempt ~= nil then
		if attempt.token ~= nil and attempt.token ~= token then return nil, 'commit_token_mismatch' end
		local existing_policy = attempt.policy or attempt.commit_policy
		if existing_policy ~= nil and existing_policy ~= policy then return nil, 'commit_policy_mismatch' end
	end

	local seq = next_sequence_value(self._jobs)
	local job = copy(current)
	job.commit_attempt = copy(attempt or {})
	job.commit_attempt.token = token
	job.commit_attempt.policy = policy
	job.commit_attempt.active_token = expected_active_token
	job.commit_attempt.generation = cmd.generation or job.generation
	job.commit_attempt.acceptance = 'accepted'
	job.commit_attempt.accepted = true
	job.commit_attempt.accepted_result = copy(cmd.accepted or cmd.result or {})
	job.commit_attempt.accepted_seq = seq
	job.commit_attempt.reason = cmd.reason or 'commit_accepted'

	repo_mod.mark_awaiting_return(job, cmd.accepted or cmd.result or {}, { seq = seq, reason = cmd.reason or 'commit_accepted' })
	job.active_token = nil
	job.active = nil
	job.active_intent = nil

	repo_mod.patch(job, {
		commit_attempt = job.commit_attempt,
		active_token = nil,
		active = nil,
		active_intent = nil,
	}, { seq = seq, reason = cmd.reason or 'commit_accepted' })

	return {
		kind = 'save_job',
		transition = cmd.kind,
		job = job,
		job_id = job.job_id,
		phase = 'commit',
		token = expected_active_token,
		commit_token = token,
		commit_policy = policy,
		next_seq = seq + 1,
		public_result = {
			tag = 'commit_accepted',
			job_id = job.job_id,
			phase = 'commit',
			token = expected_active_token,
			commit_token = token,
			commit_policy = policy,
			job = public_job(job),
		},
	}, nil
end

local function compute_apply_active(self, cmd)
	local ev = assert(cmd.event or cmd.active_event or cmd.completion, 'active completion event required')
	local current = ev.job_id and self._jobs.jobs[ev.job_id] or nil
	if not current then return nil, 'not_found' end

	local expected_token = current.active_token or (current.active and current.active.token)
	if expected_token == nil then
		-- Reconcile is idempotent observation of an already-durable
		-- awaiting_return job. Commit completion may also arrive after the commit
		-- worker has already persisted commit_accepted and cleared active intent; in
		-- that case durable apply is a confirmation, not the first accepted boundary.
		if ev.phase == 'commit' and current.state == 'awaiting_return' and ev.status == 'ok' then
			local job = copy(current)
			if type(job.commit_attempt) == 'table' then
				job.commit_attempt.accepted_result = copy((ev.result or {}).commit or (ev.result or {}))
				job.commit_attempt.acceptance = 'accepted'
				job.commit_attempt.accepted = true
			end
			return {
				kind = 'save_job',
				transition = cmd.kind,
				job = job,
				job_id = job.job_id,
				phase = 'commit',
				token = ev.token,
				next_seq = next_sequence_value(self._jobs),
				public_result = {
					tag = 'active_result_applied',
					job_id = job.job_id,
					phase = ev.phase,
					token = ev.token,
					job = public_job(job),
					active = copy(ev),
				},
			}, nil
		end
		if not (ev.phase == 'reconcile' and current.state == 'awaiting_return') then
			return nil, 'not_active'
		end
	elseif ev.token ~= expected_token then
		return nil, 'stale_active_token'
	end

	local job = copy(current)
	local ok_apply, aerr = active_policy.apply_completion(job, ev, next_sequence_value(self._jobs))
	if ok_apply ~= true then return nil, aerr or 'active_completion_apply_failed' end
	if ev.phase == 'commit' and type(job.commit_attempt) == 'table' then
		job.commit_attempt.acceptance = ev.status == 'ok' and 'accepted' or (ev.status or 'failed')
		job.commit_attempt.accepted_result = copy((ev.result or {}).commit or (ev.result or {}))
	end
	job.active_token = nil
	job.active = nil
	job.active_intent = nil

	return {
		kind = 'save_job',
		transition = cmd.kind,
		job = job,
		job_id = job.job_id,
		next_seq = next_sequence_value(self._jobs) + 1,
		public_result = {
			tag = 'active_result_applied',
			job_id = job.job_id,
			phase = ev.phase,
			token = ev.token,
			job = public_job(job),
			active = copy(ev),
		},
	}, nil
end

local function compute_patch(self, cmd)
	local current = cmd.job_id and self._jobs.jobs[cmd.job_id] or nil
	if not current then return nil, 'not_found' end
	local job = copy(current)
	local public, err = repo_mod.patch(job, cmd.patch or {}, {
		seq = next_sequence_value(self._jobs),
		reason = cmd.reason or cmd.kind or 'patch_job',
	})
	if not public then return nil, err end
	return {
		kind = 'save_job',
		transition = cmd.kind,
		job = job,
		job_id = job.job_id,
		next_seq = next_sequence_value(self._jobs) + 1,
		public_result = {
			tag = 'job_patched',
			method = cmd.kind,
			job_id = job.job_id,
			job = public_job(job),
		},
	}, nil
end

local function compute_discard(self, cmd)
	local current = cmd.job_id and self._jobs.jobs[cmd.job_id] or nil
	if not current then return nil, 'not_found' end
	return {
		kind = 'delete_job',
		transition = cmd.kind,
		job_id = cmd.job_id,
		public_result = {
			tag = 'job_discarded',
			method = cmd.kind,
			job_id = cmd.job_id,
			job = public_job(current),
		},
	}, nil
end

local function compute_transition(self, cmd)
	if type(cmd) ~= 'table' then return nil, 'transition command required' end
	if type(cmd.kind) ~= 'string' then return nil, 'transition kind required' end

	if GENERATION_VALIDATED_TRANSITIONS[cmd.kind] then
		local ok_gen, gen_err = validate_generation(cmd, self._current_generation)
		if ok_gen ~= true then return nil, gen_err end
	end

	if cmd.kind == 'create_job' then
		return compute_create(self, cmd)
	elseif cmd.kind == 'start_job' or cmd.kind == 'mark_starting' then
		return compute_start(self, cmd)
	elseif cmd.kind == 'begin_commit_attempt' then
		return compute_begin_commit_attempt(self, cmd)
	elseif cmd.kind == 'commit_accepted' then
		return compute_commit_accepted(self, cmd)
	elseif cmd.kind == 'apply_active_result' then
		return compute_apply_active(self, cmd)
	elseif cmd.kind == 'patch_job' or cmd.kind == 'mark_job' then
		return compute_patch(self, cmd)
	elseif cmd.kind == 'discard_job' or cmd.kind == 'delete_job' then
		return compute_discard(self, cmd)
	end

	return nil, 'unsupported_job_transition: ' .. tostring(cmd.kind)
end

local function apply_plan(self, plan)
	if plan.kind == 'save_job' then
		local saved, err = repo_mod.upsert(self._jobs, plan.job)
		if not saved then return nil, err end
		if plan.next_seq and plan.next_seq > (self._jobs.next_seq or 1) then
			self._jobs.next_seq = plan.next_seq
		end
	elseif plan.kind == 'delete_job' then
		local ok, err = repo_mod.remove(self._jobs, plan.job_id)
		if ok ~= true then return nil, err end
	else
		return nil, 'unsupported_plan_kind'
	end

	self._model:set_snapshot(runtime_snapshot(self, self._ready, self._adoption))
	return true, nil
end

local function start_transition_worker(self, req, plan)
	local identity = {
		kind = 'job_transition_done',
		service_id = self._service_id,
		transition_id = req.id,
		transition = plan.transition,
		job_id = plan.job_id,
		generation = req.cmd and req.cmd.generation,
		phase = req.cmd and req.cmd.phase,
		token = req.cmd and req.cmd.token,
	}

	local handle, err = scoped_work.start {
		lifetime_scope = self._scope,
		reaper_scope = self._scope,
		report_scope = self._scope,
		identity = identity,

		run = function ()
			if plan.kind == 'save_job' then
				local ok, serr = fibers.perform(store_save_op(self._store, public_job(plan.job)))
				if ok ~= true then error(serr or 'job_save_failed', 0) end
			elseif plan.kind == 'delete_job' then
				local ok, derr = fibers.perform(store_delete_op(self._store, plan.job_id))
				if ok ~= true then error(derr or 'job_delete_failed', 0) end
			else
				error('unsupported_plan_kind', 0)
			end

			return {
				tag = 'job_transition_persisted',
				transition_id = req.id,
				transition = plan.transition,
				job_id = plan.job_id,
			}
		end,

		report = function (ev)
			return queue.try_admit_required(
				self._done_tx,
				ev,
				'update_job_transition_completion_report_failed'
			)
		end,
	}

	if not handle then return nil, err end

	return handle, nil
end

local record_transition_outcome

local function start_next(self)
	if self._inflight ~= nil then return true end

	while self._inflight == nil and #self._pending > 0 do
		local req = table.remove(self._pending, 1)

		local plan, perr = compute_transition(self, req.cmd)
		if not plan then
			local rec = transition_set(self, req, 'rejected', {
				sequence = req.sequence,
				error = perr or 'job_transition_rejected',
			})
			local outcome = transition_outcome_from_record(rec, {
				transition_id = req.id,
				status = 'rejected',
				transition = req.cmd and req.cmd.kind,
				job_id = req.cmd and req.cmd.job_id,
				reason = perr or 'job_transition_rejected',
			})
			record_transition_outcome(self, outcome)
			refresh_model(self)
			resolve_cell(req.cell, outcome, nil)
		else
			local rec = transition_set(self, req, 'admitted', {
				sequence = req.sequence,
				plan_kind = plan.kind,
			})
			refresh_model(self)

			rec = transition_set(self, req, 'persisting', {
				sequence = req.sequence,
				plan_kind = plan.kind,
			})
			refresh_model(self)

			local handle, herr = start_transition_worker(self, req, plan)
			if not handle then
				rec = transition_set(self, req, 'failed', {
					sequence = req.sequence,
					plan_kind = plan.kind,
					error = herr or 'job_transition_start_failed',
				})
				local outcome = transition_outcome_from_record(rec, {
					transition_id = req.id,
					status = 'failed',
					transition = req.cmd and req.cmd.kind,
					job_id = plan.job_id,
					reason = herr or 'job_transition_start_failed',
				})
				record_transition_outcome(self, outcome)
				refresh_model(self)
				resolve_cell(req.cell, outcome, nil)
			else
				req.admitted = true
				self._inflight = {
					request = req,
					plan = plan,
					handle = handle,
				}
			end
		end
	end

	return true
end

local function handle_request(self, req)
	if self._closed then
		resolve_cell(req.cell, nil, self._closed_reason or 'job_runtime_closed')
		return
	end

	req.sequence = req.sequence or (#(self._transition_order or {}) + 1)
	transition_set(self, req, 'proposed', { sequence = req.sequence })
	refresh_model(self)
	self._pending[#self._pending + 1] = req
	start_next(self)
end

local function transition_outcome(req, plan, status, reason)
	local out = {}
	if status == 'persisted' and plan.public_result then
		out = copy(plan.public_result)
	end
	out.transition_id = req.id
	out.status = status
	out.transition = plan.transition
	out.job_id = plan.job_id
	out.phase = plan.phase or (req.cmd and req.cmd.phase)
	out.token = plan.token or (req.cmd and req.cmd.token)
	out.commit_token = plan.commit_token or (req.cmd and req.cmd.commit_token) or out.commit_token
	out.commit_policy = plan.commit_policy or (req.cmd and (req.cmd.commit_policy or req.cmd.policy)) or out.commit_policy
	if status ~= 'persisted' then out.reason = reason end
	return out
end

function record_transition_outcome(self, outcome)
	self._transition_outcomes = self._transition_outcomes or {}
	self._transition_outcome_order = self._transition_outcome_order or {}
	self._transition_outcomes[outcome.transition_id] = copy(outcome)
	self._transition_outcome_order[#self._transition_outcome_order + 1] = outcome.transition_id
end

local function handle_transition_done(self, ev)
	local inflight = self._inflight
	if not inflight or ev.transition_id ~= inflight.request.id then
		return
	end

	self._inflight = nil

	local outcome
	local rec
	if ev.status == 'ok' then
		local ok, err = apply_plan(self, inflight.plan)
		if ok == true then
			rec = transition_set(self, inflight.request, 'persisted', {
				sequence = inflight.request.sequence,
				plan_kind = inflight.plan.kind,
			})
			outcome = transition_outcome_from_record(rec, transition_outcome(inflight.request, inflight.plan, 'persisted'))
		else
			rec = transition_set(self, inflight.request, 'failed', {
				sequence = inflight.request.sequence,
				plan_kind = inflight.plan.kind,
				error = err or 'job_transition_apply_failed',
			})
			outcome = transition_outcome_from_record(rec, transition_outcome(inflight.request, inflight.plan, 'failed', err or 'job_transition_apply_failed'))
		end
	else
		local reason = ev.primary or ev.status or 'job_transition_failed'
		rec = transition_set(self, inflight.request, 'failed', {
			sequence = inflight.request.sequence,
			plan_kind = inflight.plan.kind,
			error = reason,
		})
		outcome = transition_outcome_from_record(rec, transition_outcome(inflight.request, inflight.plan, 'failed', reason))
	end

	record_transition_outcome(self, outcome)
	refresh_model(self)
	resolve_cell(inflight.request.cell, outcome, nil)

	start_next(self)
end

local function map_request(req)
	if req == nil then return { kind = 'job_runtime_requests_closed' } end
	return { kind = 'transition_requested', request = req }
end

local function map_done(ev)
	if ev == nil then return { kind = 'job_runtime_done_closed' } end
	return ev
end

function Runtime:_run(scope)
	self._scope = scope
	scope:finally(function (_, status, primary)
		local reason = primary or status or 'job_runtime_closed'
		self._request_tx:close(reason)
		self._done_tx:close(reason)
		self._closed = true
		self._closed_reason = reason
		if self._inflight and self._inflight.request then
			resolve_cell(self._inflight.request.cell, nil, reason)
		end
		for _, req in ipairs(self._pending) do
			resolve_cell(req.cell, nil, reason)
		end
	end)

	local jobs, load_err = load_jobs(self._params or {})
	if not jobs then
		self._ready_err = load_err or 'job_load_failed'
		self._ready_cond:signal()
		error(self._ready_err, 0)
	end
	self._jobs = jobs
	local adoption, adopt_err = adopt_restart_jobs(self, jobs)
	if not adoption then
		self._ready_err = adopt_err or 'restart_adoption_failed'
		self._ready_cond:signal()
		error(self._ready_err, 0)
	end
	self._adoption = adoption
	self._ready = true
	self._model:set_snapshot(runtime_snapshot(self, true, self._adoption))
	self._ready_cond:signal()

	while true do
		local which, ev = fibers.perform(fibers.named_choice {
			request = self._request_rx:recv_op():wrap(map_request),
			done = self._done_rx:recv_op():wrap(map_done),
		})

		if which == 'request' then
			if ev.kind == 'job_runtime_requests_closed' then
				return { tag = 'job_runtime_stopped', reason = 'request_queue_closed' }
			end
			handle_request(self, ev.request)
		elseif which == 'done' then
			if ev.kind == 'job_runtime_done_closed' then
				return { tag = 'job_runtime_stopped', reason = 'done_queue_closed' }
			end
			handle_transition_done(self, ev)
		end
	end
end

function Runtime:ready()
	return self._ready == true
end

function Runtime:ready_op()
	return op.guard(function ()
		if self._ready then return op.always(true, nil) end
		if self._ready_err then return op.always(nil, self._ready_err) end
		return self._ready_cond:wait_op():wrap(function ()
			if self._ready then return true, nil end
			return nil, self._ready_err or self._closed_reason or 'job_runtime_closed'
		end)
	end)
end

function Runtime:version()
	return self._model:version()
end

function Runtime:changed_op(seen)
	return self._model:changed_op(seen)
end

function Runtime:snapshot()
	return repo_mod.snapshot(self._jobs or { jobs = {}, order = {}, next_seq = 1 })
end

function Runtime:model_snapshot()
	return self._model:snapshot()
end

function Runtime:adoption()
	return copy(self._adoption or {})
end

function Runtime:set_current_generation(generation)
	self._current_generation = generation
	return true, nil
end

function Runtime:current_generation()
	return self._current_generation
end

function Runtime:transition_snapshot()
	return transition_snapshot(self)
end

function Runtime:transition_outcome(transition_id)
	local out = self._transition_outcomes and self._transition_outcomes[transition_id] or nil
	return out and copy(out) or nil
end

function Runtime:list()
	return repo_mod.list(self._jobs or { jobs = {}, order = {} })
end

function Runtime:get(job_id)
	return repo_mod.get(self._jobs or { jobs = {} }, job_id)
end

function Runtime:admit_transition(cmd)
	local cell = make_cell()
	local req = {
		id = tostring(self._next_transition_id),
		cmd = copy(cmd),
		cell = cell,
	}
	self._next_transition_id = self._next_transition_id + 1

	if self._closed then
		return nil, self._closed_reason or 'job_runtime_closed'
	end

	if self._ready ~= true then
		return nil, self._ready_err or 'job_runtime_not_ready'
	end

	local ok, err = queue.try_admit_now(self._request_tx, req)
	if ok ~= true then
		return nil, err or 'job_runtime_busy'
	end

	return new_transition_handle(req), nil
end

function Runtime:terminate(reason)
	return self:cancel(reason or 'job_runtime_terminated')
end

function Runtime:cancel(reason)
	if self._handle and self._handle.cancel then
		return self._handle:cancel(reason or 'job_runtime_cancelled')
	end
	self._request_tx:close(reason or 'job_runtime_cancelled')
	return true
end

local function empty_jobs()
	return { jobs = {}, order = {}, next_seq = 1, dirty = {} }
end

local function new_runtime(scope, params)
	local request_tx, request_rx = mailbox.new(params.queue_len or DEFAULT_QUEUE, { full = 'reject_newest' })
	local done_tx, done_rx = mailbox.new(params.done_queue_len or DEFAULT_QUEUE, { full = 'reject_newest' })
	local initial_jobs = empty_jobs()
	local runtime = setmetatable({
		_scope = scope,
		_service_id = params.service_id or 'update',
		_store = params.store,
		_params = params,
		_jobs = initial_jobs,
		_adoption = {},
		_ready = false,
		_ready_err = nil,
		_ready_cond = cond.new(),
		_request_tx = request_tx,
		_request_rx = request_rx,
		_done_tx = done_tx,
		_done_rx = done_rx,
		_pending = {},
		_inflight = nil,
		_next_transition_id = 1,
		_closed = false,
		_closed_reason = nil,
		_current_generation = params.current_generation,
		_transition_outcomes = {},
		_transition_order = {},
		_model = model_mod.new(runtime_snapshot(initial_jobs, false, {}), { label = 'update.job_runtime' }),
	}, Runtime)

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'job_runtime_parent_closed'
		runtime._model:terminate(reason)
		request_tx:close(reason)
		done_tx:close(reason)
		if runtime._ready ~= true and runtime._ready_err == nil then
			runtime._ready_err = reason
			runtime._ready_cond:signal()
		end
	end)

	return runtime
end

function M.start(scope, params)
	params = params or {}
	local runtime = new_runtime(scope, params)

	local handle, herr = scoped_work.start {
		lifetime_scope = scope,
		reaper_scope = scope,
		report_scope = scope,
		identity = {
			kind = 'component_done',
			service_id = params.service_id or 'update',
			component = 'job_runtime',
		},
		run = function (component_scope)
			return runtime:_run(component_scope)
		end,
		report = function (ev)
			if params.done_tx == nil then return true, nil end
			return queue.try_admit_required(
				params.done_tx,
				ev,
				'update_job_runtime_component_completion_report_failed'
			)
		end,
	}

	if not handle then
		runtime._model:terminate(herr or 'job_runtime_start_failed')
		runtime._request_tx:close(herr or 'job_runtime_start_failed')
		runtime._done_tx:close(herr or 'job_runtime_start_failed')
		runtime._ready_err = herr or 'job_runtime_start_failed'
		runtime._ready_cond:signal()
		return nil, herr
	end

	runtime._handle = handle
	return runtime, nil, nil
end


M.Runtime = Runtime

return M
