-- services/update/model.lua
--
-- In-memory update service state and transition helpers.
--
-- Top-level state record:
--   {
--     cfg = <merged service config>,
--     store = { jobs = { [id] = job }, order = { id... } },
--     seq = <monotonic in-service sequence>,
--     active_job = { job_id, scope, component, started_at, mode } | nil,
--     locks = { global = job_id | nil },
--     backends = { [component] = backend },
--     dirty_jobs = { [job_id] = true },
--     summary_dirty = boolean,
--     component_obs = { [key] = observer_rec },
--   }
--
-- Durable job fields live on the job record itself. Runtime-only fields are kept
-- under job.runtime and are stripped before persistence.

local M = {}

local ACTIVE_STATES = {
	staging = true,
	awaiting_return = true,
}

local TERMINAL_STATES = {
	succeeded = true,
	failed = true,
	rolled_back = true,
	cancelled = true,
	timed_out = true,
	superseded = true,
	discarded = true,
}

local PASSIVE_STATES = {
	created = true,
	awaiting_commit = true,
}

local function copy_value(v, seen)
	if type(v) ~= 'table' then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, vv in pairs(v) do
		out[copy_value(k, seen)] = copy_value(vv, seen)
	end
	return out
end

M.copy_value = copy_value
M.ACTIVE_STATES = ACTIVE_STATES
M.TERMINAL_STATES = TERMINAL_STATES
M.PASSIVE_STATES = PASSIVE_STATES

function M.default_cfg(schema)
	return {
		schema = schema,
		jobs_namespace = 'update/jobs',
		reconcile = {
			interval_s = 10.0,
			timeout_s = 180.0,
		},
		artifacts = {
			default_policy = 'transient_only',
			policies = {
				cm5 = 'transient_only',
				mcu = 'transient_only',
			},
		},
		components = {
			cm5 = { backend = 'cm5_swupdate' },
			mcu = { backend = 'mcu_component' },
		},
		bundled = {
			components = {},
		},
	}
end

function M.merge_cfg(payload, schema)
	local cfg = M.default_cfg(schema)
	local data = payload and (payload.data or payload) or nil
	if type(data) ~= 'table' then return cfg end
	if data.schema ~= nil and data.schema ~= schema then return cfg end

	if type(data.jobs_namespace) == 'string' and data.jobs_namespace ~= '' then
		cfg.jobs_namespace = data.jobs_namespace
	end

	if type(data.reconcile) == 'table' then
		if type(data.reconcile.interval_s) == 'number' and data.reconcile.interval_s > 0 then
			cfg.reconcile.interval_s = data.reconcile.interval_s
		end
		if type(data.reconcile.timeout_s) == 'number' and data.reconcile.timeout_s > 0 then
			cfg.reconcile.timeout_s = data.reconcile.timeout_s
		end
	end

	if type(data.artifacts) == 'table' then
		if type(data.artifacts.default_policy) == 'string' and data.artifacts.default_policy ~= '' then
			cfg.artifacts.default_policy = data.artifacts.default_policy
		end
		if type(data.artifacts.policies) == 'table' then
			for component, policy in pairs(data.artifacts.policies) do
				if type(component) == 'string' and type(policy) == 'string' and policy ~= '' then
					cfg.artifacts.policies[component] = policy
				end
			end
		end
	end

	if type(data.components) == 'table' then
		cfg.components = {}
		for component, spec in pairs(data.components) do
			if type(component) == 'string' and type(spec) == 'table' then
				local backend = type(spec.backend) == 'string' and spec.backend or nil
				if backend and backend ~= '' then
					local rec = { backend = backend }
					if type(spec.transfer) == 'table' then
						rec.transfer = copy_value(spec.transfer)
					end
					if type(spec.timeout_prepare) == 'number' and spec.timeout_prepare > 0 then
						rec.timeout_prepare = spec.timeout_prepare
					end
					if type(spec.timeout_stage) == 'number' and spec.timeout_stage > 0 then
						rec.timeout_stage = spec.timeout_stage
					end
					if type(spec.timeout_commit) == 'number' and spec.timeout_commit > 0 then
						rec.timeout_commit = spec.timeout_commit
					end
					cfg.components[component] = rec
				end
			end
		end
	end

	if type(data.bundled) == 'table' then
		if type(data.bundled.components) == 'table' then
			cfg.bundled.components = {}
			for component, spec in pairs(data.bundled.components) do
				if type(component) == 'string' and type(spec) == 'table' then
					local rec = copy_value(spec)
					rec.enabled = spec.enabled == true
					rec.follow_mode_default = (spec.follow_mode_default == 'hold') and 'hold' or 'auto'
					rec.auto_start = spec.auto_start ~= false
					rec.auto_commit = spec.auto_commit ~= false
					rec.retry_on_boot = spec.retry_on_boot ~= false
					cfg.bundled.components[component] = rec
				end
			end
		end
	end

	return cfg
end

function M.new_state(cfg)
	return {
		cfg = cfg,
		store = { jobs = {}, order = {} },
		seq = 0,
		active_job = nil,
		locks = { global = nil },
		backends = {},
		dirty_jobs = {},
		summary_dirty = false,
		component_obs = {},
		component_summaries = {},
	}
end

function M.seed_seq_from_store(state)
	local maxv = 0
	for _, id in ipairs(state.store.order) do
		local job = state.store.jobs[id]
		if job then
			if type(job.created_seq) == 'number' and job.created_seq > maxv then maxv = job.created_seq end
			if type(job.updated_seq) == 'number' and job.updated_seq > maxv then maxv = job.updated_seq end
		end
	end
	state.seq = maxv
end

function M.next_seq(state)
	state.seq = state.seq + 1
	return state.seq
end

function M.sort_store(state)
	table.sort(state.store.order, function(a, b)
		local ja, jb = state.store.jobs[a], state.store.jobs[b]
		local ta = (ja and (ja.created_seq or ja.created_mono)) or 0
		local tb = (jb and (jb.created_seq or jb.created_mono)) or 0
		if ta == tb then return tostring(a) < tostring(b) end
		return ta < tb
	end)
end

function M.load_store(state, loaded)
	state.store = loaded or { jobs = {}, order = {} }
	M.sort_store(state)
	for _, id in ipairs(state.store.order) do
		local job = state.store.jobs[id]
		if job then
			job.runtime = type(job.runtime) == 'table' and job.runtime or {}
		end
	end
	M.seed_seq_from_store(state)
end

function M.mark_job_dirty(state, job_id)
	if type(job_id) == 'string' and job_id ~= '' then
		state.dirty_jobs[job_id] = true
	end
	state.summary_dirty = true
end

function M.mark_all_jobs_dirty(state)
	for _, id in ipairs(state.store.order) do
		state.dirty_jobs[id] = true
	end
	state.summary_dirty = true
end

function M.mark_summary_dirty(state)
	state.summary_dirty = true
end

function M.clear_job_dirty(state, job_id)
	state.dirty_jobs[job_id] = nil
end

function M.set_summary_clean(state)
	state.summary_dirty = false
end

function M.is_terminal(st)
	return TERMINAL_STATES[st] == true
end

function M.is_active(st)
	return ACTIVE_STATES[st] == true
end

function M.job_actions(job)
	local st = job and job.state or nil
	local has_retry_artifact = type(job) == 'table'
		and type(job.artifact_ref) == 'string'
		and job.artifact_ref ~= ''

	return {
		start = (st == 'created'),
		commit = (st == 'awaiting_commit'),
		cancel = (st == 'created' or st == 'awaiting_commit'),
		retry = has_retry_artifact and (st == 'failed' or st == 'rolled_back' or st == 'timed_out' or st == 'cancelled'),
		discard = TERMINAL_STATES[st] == true,
	}
end

function M.touch_job(state, job, now_mono, service_run_id, state_changed, runtime_merge)
	if runtime_merge then
		job.runtime = type(job.runtime) == 'table' and job.runtime or {}
		for k, v in pairs(runtime_merge) do
			job.runtime[k] = v
		end
	end

	if state_changed then
		job.runtime = type(job.runtime) == 'table' and job.runtime or {}
		job.runtime.phase_run_id = service_run_id
		job.runtime.phase_mono = now_mono
	end

	job.updated_seq = M.next_seq(state)
	job.updated_mono = now_mono
end

function M.patch_job(state, job, patch, now_mono, service_run_id, opts)
	opts = opts or {}
	local state_changed = false

	for k, v in pairs(patch) do
		if job[k] ~= v then
			if k == 'state' then state_changed = true end
			job[k] = v
		end
	end

	M.touch_job(state, job, now_mono, service_run_id, state_changed, opts.runtime_merge)
	M.mark_job_dirty(state, job.job_id)
end

function M.add_job(state, job)
	state.store.jobs[job.job_id] = job
	state.store.order[#state.store.order + 1] = job.job_id
	M.sort_store(state)
	M.mark_job_dirty(state, job.job_id)
end

function M.remove_job(state, job_id)
	state.store.jobs[job_id] = nil
	for i = #state.store.order, 1, -1 do
		if state.store.order[i] == job_id then
			table.remove(state.store.order, i)
			break
		end
	end
	M.mark_summary_dirty(state)
end

function M.select_resumable_job(state)
	if state.active_job or state.locks.global ~= nil then
		return nil
	end

	for _, id in ipairs(state.store.order) do
		local job = state.store.jobs[id]
		if job and job.state == 'awaiting_return' and job.next_step == 'reconcile' then
			return job
		end
	end

	return nil
end

function M.can_activate(state, job)
	if state.active_job and state.active_job.job_id == job.job_id then
		return nil, 'job_already_active'
	end
	if state.locks.global ~= nil then
		return nil, 'busy_global'
	end
	return true, nil
end

function M.acquire_lock(state, job, now_mono, service_run_id)
	state.locks.global = job.job_id
	job.runtime = type(job.runtime) == 'table' and job.runtime or {}
	job.runtime.active_lock = 'global:' .. tostring(job.job_id)
	M.touch_job(state, job, now_mono, service_run_id, false, nil)
	M.mark_job_dirty(state, job.job_id)
end

function M.release_lock(state, job, now_mono, service_run_id)
	if not job then return end

	if type(job.runtime) == 'table' and job.runtime.active_lock ~= nil then
		job.runtime.active_lock = nil
		M.touch_job(state, job, now_mono, service_run_id, false, nil)
		M.mark_job_dirty(state, job.job_id)
	end

	if state.locks.global == job.job_id then
		state.locks.global = nil
	end
	M.mark_summary_dirty(state)
end

function M.set_active_job(state, rec)
	state.active_job = rec
	M.mark_summary_dirty(state)
end

function M.clear_active_job(state)
	state.active_job = nil
	M.mark_summary_dirty(state)
end

function M.adopt_persisted_jobs(state, now_mono, service_run_id)
	local changed = false

	for _, id in ipairs(state.store.order) do
		local job = state.store.jobs[id]
		if job then
			if job.state == 'staging' then
				if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
					M.patch_job(state, job, {
						state = 'created',
						next_step = nil,
						error = job.error,
					}, now_mono, service_run_id, {
						runtime_merge = { adopted = true },
					})
				else
					M.patch_job(state, job, {
						state = 'failed',
						next_step = nil,
						error = 'interrupted_before_stage',
					}, now_mono, service_run_id, {
						runtime_merge = { adopted = true },
					})
				end
				changed = true

			elseif job.state == 'awaiting_return' then
				M.patch_job(state, job, {
					state = 'awaiting_return',
					next_step = 'reconcile',
				}, now_mono, service_run_id, {
					runtime_merge = { adopted = true },
				})
				changed = true

			elseif job.state == 'awaiting_approval' or job.state == 'deferred' or job.state == 'staged' then
				M.patch_job(state, job, {
					state = 'awaiting_commit',
					next_step = 'commit',
				}, now_mono, service_run_id, {
					runtime_merge = { adopted = true },
				})
				changed = true
			end
		end
	end

	return changed
end

function M.create_job(state, spec, now_mono, service_run_id)
	local created_seq = M.next_seq(state)
	local job = {
		job_id = spec.job_id,
		offer_id = spec.offer_id,
		component = spec.component,
		artifact_ref = spec.artifact_ref,
		artifact_meta = spec.artifact_meta,
		expected_image_id = spec.expected_image_id,
		metadata = spec.metadata,
		auto_start = (spec.auto_start == true),
		auto_commit = (spec.auto_commit == true),
		state = 'created',
		stage = 'created',
		next_step = nil,
		created_seq = created_seq,
		updated_seq = created_seq,
		created_mono = now_mono,
		updated_mono = now_mono,
		result = nil,
		error = nil,
		runtime = {
			attempt = 0,
			adopted = false,
			active_lock = nil,
			last_progress = nil,
			phase_run_id = service_run_id,
			phase_mono = now_mono,
		},
	}
	M.add_job(state, job)
	return job
end

return M
