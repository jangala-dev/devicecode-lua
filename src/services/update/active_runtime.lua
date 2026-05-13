-- services/update/active_runtime.lua
--
-- Service-owned active-slot reducer plus lease/start helpers.
--
-- The active slot is coordinator state, not a lifetime boundary. A lease grants
-- immediate authority to start active work. Once work is successfully started,
-- the active work scope owns the running operation. The component stores the
-- completion, applies it through job_runtime, and releases the slot only after
-- durable apply.

local fibers      = require 'fibers'
local mailbox     = require 'fibers.mailbox'
local scoped_work = require 'devicecode.support.scoped_work'
local queue       = require 'devicecode.support.queue'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local model       = require 'services.update.model'
local active_job  = require 'services.update.active_job'
local observe_mod = require 'services.update.observe'

local M = {}

local State = {}
State.__index = State

local Lease = {}
Lease.__index = Lease

local function copy(v)
	return model.deep_copy(v)
end

local function token_for(job_id, generation, phase, seq)
	return table.concat({
		tostring(generation or 0),
		tostring(job_id),
		tostring(phase or 'stage'),
		tostring(seq or 0),
	}, ':')
end

local function new_stats()
	return {
		accepted      = 0,
		rejected_busy = 0,
		completed     = 0,
		stale         = 0,
		failed        = 0,
		cancelled     = 0,
		released      = 0,
	}
end

local function active_matches(state, token)
	return state and state.active and state.active.token == token
end

local function active_public(active)
	if not active then return nil end
	return {
		service_id = active.service_id,
		job_id     = active.job_id,
		generation = active.generation,
		phase      = active.phase,
		token      = active.token,
		status     = active.status,
		job        = active.job and copy(active.job) or nil,
	}
end

function M.new_state(_opts)
	return setmetatable({
		active     = nil,
		next_token = 1,
		stats      = new_stats(),
		completions = {},
		completion_order = {},
	}, State)
end

function M.snapshot(state)
	return {
		active = active_public(state and state.active or nil),
		stats  = copy((state and state.stats) or {}),
		last_completion = state and state.last_completion and copy(state.last_completion) or nil,
	}
end

function M.is_idle(state)
	return state == nil or state.active == nil
end

local function make_lease(state, rec, token)
	return setmetatable({
		_state       = state,
		_transferred = false,
		_released    = false,

		service_id   = rec.service_id,
		job_id       = rec.job_id,
		generation   = rec.generation,
		phase        = rec.phase or 'stage',
		token        = token,
	}, Lease)
end

function M.claim(state, rec)
	assert(state, 'active_runtime.claim: state required')

	if state.active ~= nil then
		state.stats.rejected_busy = state.stats.rejected_busy + 1
		return nil, 'slot_busy'
	end

	rec = rec or {}
	local seq = state.next_token or 1
	state.next_token = seq + 1

	local token = rec.token or token_for(rec.job_id, rec.generation, rec.phase or 'stage', seq)
	local lease = make_lease(state, rec, token)

	state.active = {
		service_id = lease.service_id,
		job_id     = lease.job_id,
		generation = lease.generation,
		phase      = lease.phase,
		token      = lease.token,
		status     = 'leased',
		handle     = nil,
	}
	state.stats.accepted = state.stats.accepted + 1

	return lease, nil
end

function Lease:release(reason)
	local state = self._state
	if self._released then
		return false, 'already_released'
	end
	if self._transferred then
		return false, 'transferred'
	end
	if not active_matches(state, self.token) then
		return false, 'not_owner'
	end

	state.active = nil
	state.stats.released = state.stats.released + 1
	self._released = true
	return true, reason
end

function Lease:handoff()
	if not active_matches(self._state, self.token) then
		return nil, 'stale'
	end
	self._transferred = true
	self._state.active.status = 'running'
	return true, nil
end

function Lease:terminate(reason)
	return self:release(reason or 'active_lease_terminated')
end

function Lease:attach_handle(handle, job)
	if not active_matches(self._state, self.token) then
		return nil, 'stale'
	end
	self._state.active.handle = handle
	self._state.active.status = 'running'
	self._state.active.job = job and copy(job) or nil
	return true, nil
end

local function default_runner(spec, lease)
	return function (scope)
		return active_job.run(scope, {
			phase    = lease.phase,
			job      = spec.job,
			backend  = spec.backend,
			observer = spec.observer,
			deadline = spec.deadline,
			ctx      = spec.ctx,
			lease    = lease,
			jobs     = spec.jobs,
		})
	end
end

local function topic_to_string(topic)
	local out = {}
	for i = 1, #(topic or {}) do out[i] = tostring(topic[i]) end
	return table.concat(out, '/')
end

local function retained_device_component_id(topic)
	if type(topic) ~= 'table' then return nil end
	if topic[1] ~= 'state' or topic[2] ~= 'device' or topic[3] ~= 'component' then return nil end
	if type(topic[4]) ~= 'string' or topic[4] == '' then return nil end
	if topic[5] ~= nil then return nil end
	return topic[4]
end

local function start_device_observer(scope, conn, observer)
	if type(conn) ~= 'table' or type(conn.watch_retained) ~= 'function' then
		return true, nil, nil
	end
	local watch, err = bus_cleanup.watch_retained(conn, { 'state', 'device', 'component', '#' }, {
		replay = true,
		queue_len = 32,
		full = 'drop_oldest',
	})
	if not watch then
		return nil, err or 'watch_retained_failed'
	end

	local closed = false
	local function close()
		if closed then return true, nil end
		closed = true
		return bus_cleanup.unwatch_retained(conn, watch)
	end

	scope:finally(function ()
		close()
	end)

	local spawn = fibers.spawn
	if type(scope) == 'table' and type(scope.spawn) == 'function' then
		spawn = function (fn)
			return scope:spawn(fn)
		end
	end

	local ok, spawn_err = spawn(function ()
		while true do
			local ev, recv_err = fibers.perform(watch:recv_op())
			if ev == nil then
				return {
					tag = 'active_device_observer_stopped',
					reason = recv_err,
				}
			end
			if ev.op == 'replay_done' then
				-- Component snapshots are applied individually as retain events.
			else
				local component = retained_device_component_id(ev.topic)
				if component ~= nil then
					if ev.op == 'retain' and type(ev.payload) == 'table' then
						observer:update_component(component, ev.payload, {
							topic = topic_to_string(ev.topic),
						})
					elseif ev.op == 'unretain' then
						observer:remove_component(component, 'unretained')
					end
				end
			end
		end
	end)
	if not ok then
		close()
		return nil, spawn_err or 'active device observer spawn failed'
	end
	return true, nil, close
end

function Lease:start_work(lifetime_scope, spec)
	spec = spec or {}

	if self._released then
		return nil, 'active lease already released'
	end
	if self._transferred then
		return nil, 'active lease already transferred'
	end
	if not active_matches(self._state, self.token) then
		return nil, 'active lease is stale'
	end
	if spec.done_tx == nil then
		return nil, 'done_tx required'
	end

	local local_tx, local_rx
	if spec.local_observer_scope ~= nil then
		local_tx, local_rx = mailbox.new(1, { full = 'reject_newest' })
		spec.local_observer_scope:finally(function (_, status, primary)
			local_tx:close(primary or status or 'active job observer closed')
		end)
	end

	local identity = {
		kind       = 'active_job_done',
		service_id = self.service_id,
		generation = self.generation,
		job_id     = self.job_id,
		phase      = self.phase,
		token      = self.token,
	}

	local runner = default_runner(spec, self)
	local handle, err = scoped_work.start {
		lifetime_scope = lifetime_scope,
		reaper_scope   = spec.reaper_scope or lifetime_scope,
		report_scope   = spec.report_scope or lifetime_scope,

		identity = identity,

		run = function (scope)
			return runner(scope, spec)
		end,

		report = function (ev)
			local ok, report_err = queue.try_admit_required(
				spec.done_tx,
				ev,
				'update_active_job_completion_report_failed'
			)
			if ok ~= true then
				return nil, report_err
			end

			-- Local observers are request-local convenience only. The authoritative
			-- coordinator completion has already been admitted above.
			if local_tx ~= nil then
				queue.try_send_now(local_tx, ev)
			end

			return true, nil
		end,
	}

	if not handle then
		self:release(err or 'active_start_failed')
		return nil, err
	end

	local ok_attach, attach_err = self:attach_handle(handle, spec.job)
	if ok_attach ~= true then
		handle:cancel(attach_err or 'active_start_stale')
		self:release(attach_err or 'active_start_stale')
		return nil, attach_err or 'active_start_stale'
	end

	self._transferred = true

	if local_rx ~= nil then
		local raw_handle = handle
		local service_id = self.service_id
		local generation = self.generation
		local job_id = self.job_id
		local phase = self.phase
		local token = self.token
		handle = {}

		function handle.cancel(_, reason)
			return raw_handle:cancel(reason)
		end

		function handle.outcome_op()
			return local_rx:recv_op():wrap(function (ev, recv_err)
				if ev == nil then
					return {
						kind       = 'active_job_done',
						service_id = service_id,
						generation = generation,
						job_id     = job_id,
						phase      = phase,
						token      = token,
						status     = 'failed',
						primary    = recv_err or 'active job observer closed',
					}
				end
				return ev
			end)
		end

		function handle.outcome()
			return raw_handle:outcome()
		end

		function handle.identity()
			return raw_handle:identity()
		end
	end

	return handle, nil
end

function M.start_work(lifetime_scope, state, spec)
	spec = spec or {}
	local lease = spec.lease
	if type(lease) ~= 'table' or type(lease.start_work) ~= 'function' then
		return nil, 'active lease required'
	end
	if lease._state ~= state then
		return nil, 'active lease belongs to another state'
	end
	return lease:start_work(lifetime_scope, spec)
end

function M.cancel_active(state, reason)
	local active = state and state.active or nil
	local handle = active and active.handle or nil
	if handle and handle.cancel then
		return handle:cancel(reason or 'active_cancelled')
	end
	return false, 'no_active'
end

function M.apply_completion(state, ev)
	if not ev or ev.kind ~= 'active_job_done' then
		return false, 'not_active_completion'
	end

	local active = state and state.active or nil
	if not active or active.token ~= ev.token then
		if state and state.stats then
			state.stats.stale = state.stats.stale + 1
		end
		return false, 'stale'
	end

	local stored = copy(ev)
	state.last_completion = stored
	state.completions[ev.token] = stored
	state.completion_order[#state.completion_order + 1] = ev.token

	active.status = 'completed_pending_persist'
	active.handle = nil
	active.completion = stored
	state.stats.completed = state.stats.completed + 1
	if ev.status == 'failed' then
		state.stats.failed = state.stats.failed + 1
	elseif ev.status == 'cancelled' then
		state.stats.cancelled = state.stats.cancelled + 1
	end

	return true, nil
end

function M.release_completed(state, token, reason)
	local active = state and state.active or nil
	if not active or active.token ~= token then
		return false, 'stale'
	end
	if active.status ~= 'completed_pending_persist' then
		return false, 'not_completed'
	end
	state.active = nil
	state.stats.released = state.stats.released + 1
	return true, reason
end

function M.last_completion(state)
	return state and state.last_completion and copy(state.last_completion) or nil
end

function M.completion(state, token)
	local ev = state and token and state.completions and state.completions[token] or nil
	return ev and copy(ev) or nil
end


----------------------------------------------------------------------
-- Service-owned component wrapper
----------------------------------------------------------------------

local Component = {}
Component.__index = Component

local function component_identity(service_id)
	return {
		kind       = 'component_done',
		service_id = service_id,
		component  = 'active_runtime',
	}
end

local function is_stale_apply_reason(reason)
	return reason == 'not_active'
		or reason == 'stale_active_token'
		or reason == 'not_found'
end

local function active_intent_for(job)
	return job and (job.active_intent or job.active) or nil
end

local function reconcile_token_for(job, generation)
	return table.concat({
		tostring(generation or 0),
		tostring(job and job.job_id or ''),
		'reconcile',
		tostring(job and job.updated_seq or 0),
	}, ':')
end

function Component:state()
	return self._state
end

function Component:snapshot()
	return M.snapshot(self._state)
end

function Component:claim(rec)
	return M.claim(self._state, rec)
end

function Component:_report_to_service(ev, label)
	local ok, err = queue.try_admit_required(
		self._service_done_tx,
		ev,
		label or 'update_active_runtime_report_failed'
	)
	if ok ~= true then return nil, err end
	return true, nil
end

function Component:_report_changed(reason, extra)
	local ev = {
		kind       = 'active_runtime_changed',
		service_id = self._service_id,
		reason     = reason,
		snapshot   = M.snapshot(self._state),
	}
	for k, v in pairs(extra or {}) do
		ev[k] = v
	end
	return self:_report_to_service(ev, 'update_active_runtime_changed_report_failed')
end

function Component:_start_apply(ev)
	if not (self._jobs and type(self._jobs.admit_transition) == 'function') then
		return nil, 'job_runtime_unavailable'
	end

	local token = ev.token or ev.job_id
	if self._active_applies[token] ~= nil then
		return false, 'already_applying'
	end

	local handle, err = scoped_work.start {
		lifetime_scope = self._work_scope,
		reaper_scope   = self._work_scope,
		report_scope   = self._work_scope,

		identity = {
			kind       = 'active_job_apply_done',
			service_id = self._service_id,
			generation = ev.generation,
			job_id     = ev.job_id,
			phase      = ev.phase,
			token      = ev.token,
		},

		run = function ()
			local handle, admit_err = self._jobs:admit_transition {
				kind       = 'apply_active_result',
				generation = ev.generation,
				job_id     = ev.job_id,
				phase      = ev.phase,
				token      = ev.token,
				event      = ev,
			}
			if not handle then error(admit_err or 'active_job_apply_admission_failed', 0) end
			local result, jerr = fibers.perform(handle:outcome_op())
			if not result or result.status ~= 'persisted' then
				error(jerr or (result and result.reason) or 'active_job_apply_failed', 0)
			end
			return result
		end,

		report = function (done_ev)
			local ok, report_err = queue.try_admit_required(
				self._local_tx,
				done_ev,
				'update_active_job_apply_completion_report_failed'
			)
			if ok == true then return true, nil end

			-- During active-runtime cancellation, apply workers may be cancelled after
			-- the local coordinator queue has already been closed.  That is expected
			-- cleanup, not a lost healthy completion.
			if self._closing_reason ~= nil then
				return true, nil
			end

			return nil, report_err
		end,
	}

	if not handle then return nil, err end
	self._active_applies[token] = handle
	return handle, nil
end

function Component:_start_reconcile(job)
	if not (job and job.job_id) then return nil, 'not_ready' end
	if self._state.active ~= nil then return nil, 'slot_busy' end

	self._adoption_reconcile_started = self._adoption_reconcile_started or {}
	if self._adoption_reconcile_started[job.job_id] then
		return false, 'already_started'
	end

	local generation = job.generation or self._current_generation
	local token = reconcile_token_for(job, generation)
	self._adoption_reconcile_started[job.job_id] = true

	local handle, err = self:start_intent({
		service_id = self._service_id,
		job_id     = job.job_id,
		generation = generation,
		phase      = 'reconcile',
		token      = token,
	}, job, {
		backend = self._backend,
		phase   = 'reconcile',
	})

	if not handle then
		self._adoption_reconcile_started[job.job_id] = nil
		return nil, err
	end

	return handle, nil
end

function Component:_start_restart_adoption()
	local adoption = self._adoption or {}
	for _, rec in ipairs(adoption.awaiting_return or {}) do
		local job = self._jobs and self._jobs:get(rec.job_id) or nil
		if job and job.state == 'awaiting_return' then
			local ok, err = self:_start_reconcile(job)
			if ok == nil and err ~= 'slot_busy' and err ~= 'reconcile_backend_unavailable' then
				return nil, err or 'restart_reconcile_start_failed'
			end
			if ok ~= nil then
				return ok, err
			end
		end
	end
	return false, 'no_reconcile_adoption'
end

function Component:_launch_active_intent(job)
	if not (job and job.job_id) then return nil, 'not_ready' end
	local intent = active_intent_for(job)
	if type(intent) ~= 'table' or intent.token == nil or intent.phase == nil then
		return false, 'no_active_intent'
	end
	if self._state.active ~= nil then return nil, 'slot_busy' end
	self._active_launched = self._active_launched or {}
	if self._active_launched[intent.token] then
		return false, 'already_started'
	end

	self._active_launched[intent.token] = true
	local handle, err = self:start_intent({
		service_id = self._service_id,
		job_id     = job.job_id,
		generation = intent.generation or job.generation,
		phase      = intent.phase,
		token      = intent.token,
	}, job, {
		backend = self._backend,
		phase   = intent.phase,
	})

	if not handle then
		self._active_launched[intent.token] = nil
		return nil, err
	end

	local ok_report, report_err = self:_report_changed('active_intent_started', {
		job_id = job.job_id,
		token = intent.token,
		phase = intent.phase,
	})
	if ok_report ~= true then return nil, report_err end
	return handle, nil
end

function Component:update_adoption(adoption)
	self._adoption = copy(adoption or {})
	return true, nil
end

function Component:consider_jobs()
	if not self._jobs then return false, 'not_ready' end
	if self._state.active ~= nil then return false, 'slot_busy' end

	local jobs = self._jobs:list()
	for _, job in ipairs(jobs) do
		local intent = active_intent_for(job)
		if type(intent) == 'table' and intent.token ~= nil and intent.phase ~= nil then
			local ok, err = self:_launch_active_intent(job)
			if ok ~= nil then return ok, err end
			if err == 'slot_busy' then return nil, err end
			return nil, err or 'active_intent_launch_failed'
		end
	end

	local ok, err = self:_start_restart_adoption()
	if ok ~= nil then return ok, err end
	if err == 'slot_busy' or err == 'no_reconcile_adoption' or err == 'not_ready' then
		return false, 'no_active_intent'
	end
	return nil, err
end

function Component:start_intent(intent, job, spec)
	intent = intent or {}
	spec = spec or {}
	if self._state.active ~= nil then
		return nil, 'slot_busy'
	end
	local lease, lerr = M.claim(self._state, {
		service_id = intent.service_id or self._service_id,
		job_id = intent.job_id or (job and job.job_id),
		generation = intent.generation or (job and job.generation),
		phase = intent.phase or 'stage',
		token = intent.token,
	})
	if not lease then return nil, lerr end

	spec.lease = lease
	spec.job = job
spec.phase = intent.phase or spec.phase or lease.phase
spec.jobs = spec.jobs or self._jobs
spec.done_tx = self._local_tx
spec.observer = spec.observer or self._observer
	local handle, herr = M.start_work(self._work_scope, self._state, spec)
	if not handle then
		lease:release(herr or 'active_intent_start_failed')
		return nil, herr
	end
	return handle, nil
end

function Component:start_work(spec)
	spec = spec or {}
	spec.done_tx = self._local_tx
	spec.jobs = spec.jobs or self._jobs
	spec.observer = spec.observer or self._observer
	return M.start_work(self._work_scope, self._state, spec)
end

function Component:cancel_active(reason)
	return M.cancel_active(self._state, reason)
end

function Component:release_completed(token, reason)
	return M.release_completed(self._state, token, reason)
end

function Component:terminate(reason)
	return self:cancel(reason or 'active_runtime_terminated')
end

function Component:cancel(reason)
	reason = reason or 'active_runtime_cancelled'
	self._closing_reason = self._closing_reason or reason

	-- The component owns both the coordinator fibre and any active/apply work it
	-- has started.  Cancelling only the coordinator handle can leave scoped work
	-- running under the component's work scope, which is especially visible when
	-- an apply worker is blocked waiting for job_runtime.
	local active = self._state and self._state.active or nil
	if active and active.handle and active.handle.cancel then
		active.handle:cancel(reason)
	end

	for token, handle in pairs(self._active_applies or {}) do
		if handle and handle.cancel then
			handle:cancel(reason)
		end
		self._active_applies[token] = nil
	end

	if self._observer_close then
		self._observer_close()
		self._observer_close = nil
	end

	if self._handle and self._handle.cancel then
		self._handle:cancel(reason)
	else
		self._local_tx:close(reason)
	end

	return true
end

function Component:_handle_active_done(ev)
	local applied, aerr = M.apply_completion(self._state, ev)
	if not applied then
		if aerr == 'stale' then
			return true, nil
		end
		return nil, aerr or 'active_runtime_apply_failed'
	end

	local ok_change, cerr = self:_report_changed('active_job_completed', {
		job_id = ev.job_id,
		phase = ev.phase,
		token = ev.token,
	})
	if ok_change ~= true then return nil, cerr end

	local handle, err = self:_start_apply(ev)
	if handle == nil and err ~= nil then
		return nil, err
	end
	return true, nil
end

function Component:_handle_apply_done(ev)
	local token = ev.token or ev.job_id
	self._active_applies[token] = nil

	if ev.status ~= 'ok' then
		local reason = ev.primary or 'active_job_apply_failed'
		M.release_completed(self._state, ev.token, reason)
		local ok_report, report_err = self:_report_changed('active_job_apply_failed', {
			job_id = ev.job_id,
			phase = ev.phase,
			token = ev.token,
			error = reason,
		})
		if ok_report ~= true then return nil, report_err end

		if is_stale_apply_reason(reason) then
			return true, nil
		end
		return nil, reason
	end

	local result = ev.result or {}
	local active_ev = result.active or {
		kind       = 'active_job_done',
		service_id = ev.service_id,
		generation = ev.generation,
		job_id     = ev.job_id,
		phase      = ev.phase,
		token      = ev.token,
		status     = ev.status,
	}
	active_ev.persisted_job = result.job
	active_ev.persistence_owner = 'job_runtime'

	M.release_completed(self._state, ev.token, 'durable_apply_complete')

	local ok_change, cerr = self:_report_changed('active_job_applied', {
		job_id = ev.job_id,
		phase = ev.phase,
		token = ev.token,
		active = active_ev,
	})
	if ok_change ~= true then return nil, cerr end

	if ev.phase == 'commit' then
		local job = result.job
		if job and job.state == 'awaiting_return' then
			local ok_rec, rerr = self:_start_reconcile(job)
			if ok_rec == nil and rerr ~= 'slot_busy' and rerr ~= 'reconcile_backend_unavailable' then
				return nil, rerr or 'reconcile_start_failed'
			end
		end
	end

	local ok_launch, launch_err = self:consider_jobs()
	if ok_launch == nil
		and launch_err ~= 'slot_busy'
		and launch_err ~= 'no_active_intent'
		and launch_err ~= 'not_ready'
	then
		return nil, launch_err or 'active_intent_launch_failed'
	end

	return true, nil
end

function Component:_handle_local_event(ev)
	if ev.kind == 'active_job_done' then
		return self:_handle_active_done(ev)
	end
	if ev.kind == 'active_job_apply_done' then
		return self:_handle_apply_done(ev)
	end
	return nil, 'unknown_active_runtime_event: ' .. tostring(ev.kind)
end

function Component:run(scope)
	scope:finally(function (_, status, primary)
		self._local_tx:close(primary or status or 'active_runtime_closed')
	end)

	while true do
		local ev = fibers.perform(self._local_rx:recv_op())
		if ev == nil then
			return {
				tag = 'active_runtime_stopped',
				snapshot = M.snapshot(self._state),
			}
		end

		local ok, err = self:_handle_local_event(ev)
		if ok ~= true then
			error(err or 'active_runtime_event_failed', 0)
		end
	end
end

--- Start the service-owned active-runtime component.
---
--- The component stores active-job completion before reporting any state change
--- to the service coordinator, applies the completion through job_runtime, and
--- releases the active slot only after durable apply.
function M.start_component(scope, params)
	params = params or {}
	local service_done_tx = assert(params.done_tx, 'active_runtime.start_component: done_tx required')
	local work_scope = assert(params.work_scope or scope, 'active_runtime.start_component: work_scope required')
	local local_tx, local_rx = mailbox.new(params.queue_len or 32, { full = 'reject_newest' })
	local observer = params.observer or observe_mod.new({
		service_id = params.service_id or 'update',
		components = params.components or {},
	})
	scope:finally(function (_, status, primary)
		observer:terminate(primary or status or 'active_runtime_closed')
	end)
	local obs_ok, obs_err, obs_close = start_device_observer(scope, params.conn, observer)
	if obs_ok ~= true then
		local_tx:close(obs_err or 'active_runtime_observer_failed')
		return nil, obs_err or 'active_runtime_observer_failed'
	end
	local component = setmetatable({
		_state = params.state or M.new_state(),
		_local_tx = local_tx,
		_local_rx = local_rx,
		_service_done_tx = service_done_tx,
		_service_id = params.service_id or 'update',
		_work_scope = work_scope,
		_jobs = params.jobs,
		_backend = params.backend,
		_observer = observer,
		_observer_close = obs_close,
		_adoption = params.adoption or {},
		_active_applies = {},
		_active_launched = {},
		_adoption_reconcile_started = {},
	}, Component)

	local handle, err = scoped_work.start {
		lifetime_scope = scope,
		reaper_scope = scope,
		report_scope = scope,
		identity = component_identity(component._service_id),
		run = function (component_scope)
			return component:run(component_scope)
		end,
		report = function (ev)
			return queue.try_admit_required(
				service_done_tx,
				ev,
				'update_active_runtime_component_completion_report_failed'
			)
		end,
	}
	if not handle then
		local_tx:close(err or 'active_runtime_start_failed')
		return nil, err
	end

	component._handle = handle
	return component, nil
end

M.Component = Component

M.State = State
M.Lease = Lease

return M
