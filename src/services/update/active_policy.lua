-- services/update/active_policy.lua
--
-- Generation-local policy for admitting and applying active update work.
--
-- The active slot itself is service-owned. This module decides whether a job is
-- eligible for active work and translates active-work completion facts into job
-- state transitions.

local repo_mod = require 'services.update.job_repository'

local M = {}

function M.phase_for(job, payload)
	payload = type(payload) == 'table' and payload or {}
	return payload.phase or (job and job.state == 'awaiting_commit' and 'commit' or 'stage')
end

function M.can_start_phase(job, phase)
	if not job then return nil, 'not_found' end
	phase = phase or M.phase_for(job)
	if type(job.runtime) == 'table' and job.runtime.persistence_pending then
		return nil, 'job_persistence_pending'
	end
	if phase == 'commit' then
		if job.state ~= 'awaiting_commit' then return nil, 'job_not_committable' end
		return true, nil
	end
	if phase == 'reconcile' then
		if job.state ~= 'awaiting_return' then return nil, 'job_not_reconcilable' end
		return true, nil
	end
	if job.state ~= 'created' then
		return nil, 'job_not_startable'
	end
	return true, nil
end

function M.can_start(job)
	return M.can_start_phase(job, M.phase_for(job))
end

function M.mark_starting(job, phase, seq)
	local updated = assert(repo_mod.normalise_job(job))
	if phase == 'commit' then
		repo_mod.mark_committing(updated, { seq = seq, reason = 'start_commit' })
	else
		repo_mod.mark_staging(updated, { seq = seq, reason = 'start_stage' })
	end
	return updated
end

function M.apply_completion(job, ev, seq)
	if not job then return false, 'not_found' end
	if not ev or ev.kind ~= 'active_job_done' then return false, 'not_active_completion' end

	if ev.status == 'ok' then
		local result = ev.result or {}
		if result.tag == 'staged' then
			repo_mod.mark_awaiting_commit(job, result.staged or result, { seq = seq, reason = 'stage_complete' })
		elseif result.tag == 'commit_started' then
			repo_mod.mark_awaiting_return(job, result.commit or result, { seq = seq, reason = 'commit_complete' })
		elseif result.tag == 'reconciled_success' then
			repo_mod.mark_terminal(job, 'succeeded', nil, result, { seq = seq, reason = 'reconcile_success' })
		elseif result.tag == 'reconcile_timeout' then
			repo_mod.mark_terminal(job, 'timed_out', 'timeout', result, { seq = seq, reason = 'reconcile_timeout' })
		elseif result.tag == 'reconcile_observer_closed' then
			repo_mod.mark_terminal(job, 'failed', result.reason or 'observer_closed', result, { seq = seq, reason = 'reconcile_observer_closed' })
		elseif result.tag == 'reconciled_failure' then
			repo_mod.mark_terminal(job, 'failed', result.reason or result.error or 'reconcile_failed', result, { seq = seq, reason = 'reconcile_failed' })
		else
			repo_mod.mark_terminal(job, 'succeeded', nil, result, { seq = seq, reason = 'active_complete' })
		end
	elseif ev.status == 'cancelled' then
		repo_mod.mark_terminal(job, 'cancelled', ev.primary or 'cancelled', nil, { seq = seq, reason = 'active_cancelled' })
	else
		repo_mod.mark_terminal(job, 'failed', ev.primary or 'failed', nil, { seq = seq, reason = 'active_failed' })
	end

	return true, nil
end

return M
