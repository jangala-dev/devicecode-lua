-- services/http/transport/cqueues_driver.lua
--
-- Fibers-facing bridge for cqueues-style pollable objects.
--
-- This module is the only place that knows how to wait for a cqueues/lua-http
-- pollable from Fibers.  The seam is deliberately small:
--   * wait on pollfd()/events()/timeout() with Fibers waitable2;
--   * treat readiness as a hint to call step(0);
--   * expose cqueues coroutine work as Fibers Ops;
--   * provide immediate termination for finalisers and abort paths.

local op        = require 'fibers.op'
local wait      = require 'fibers.wait'
local poller    = require 'fibers.io.poller'
local performer = require 'fibers.performer'
local runtime   = require 'fibers.runtime'
local safe      = require 'coxpcall'

local perform = performer.perform
local unpack  = rawget(table, 'unpack') or _G.unpack
local pack    = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local M = {}

local Driver = {}
Driver.__index = Driver

local DEFAULT_MAX_POLLABLE_TIMEOUT_S = 1.0

local function identity(...)
	return ...
end

local function tostring_error(e)
	if type(e) == 'string' or type(e) == 'number' then
		return e
	end
	return tostring(e)
end

local function is_timeout_error(err)
	if err == nil then return false end
	local s = tostring(err):lower()
	return s:find('timeout', 1, true) ~= nil
		or s:find('timed out', 1, true) ~= nil
		or s:find('again', 1, true) ~= nil
end

--- Map cqueues event strings to Fibers poll directions.
--- cqueues commonly uses r/w/p style event strings; p is treated as read-side
--- progress because it asks the outer loop to step the pollable.
local function event_wants(events)
	events = events or 'r'
	events = tostring(events)

	local rd = events:find('r', 1, true) ~= nil
		or events:find('p', 1, true) ~= nil
	local wr = events:find('w', 1, true) ~= nil

	return rd, wr
end

M.event_wants = event_wants

local function notify_waitset(waitset, key)
	local sched = runtime.current_scheduler
	if sched then waitset:notify_all(key, sched) end
end

local function new_default_cqueue()
	local ok, cqueues = pcall(require, 'cqueues')
	if not ok or not cqueues then
		return nil, 'cqueues module is not available'
	end
	return cqueues.new()
end

--- Create a new driver.
---
--- opts.controller may be supplied by tests or by lua-http server construction.
--- The controller needs the cqueues pollable protocol for run()/start() and
--- :wrap(fn) for run_op().
function M.new(opts)
	opts = opts or {}

	local controller = opts.controller
	local err
	if controller == nil and opts.create_controller ~= false then
		controller, err = new_default_cqueue()
		if not controller then return nil, err end
	end

	local self = setmetatable({
		_controller     = controller,
		_label          = opts.label or 'cqueues_driver',
		_closed         = false,
		_close_reason   = nil,
		_state_waiters  = wait.new_waitset(),
		_poke_pending   = false,
		_job_waiters    = wait.new_waitset(),
		_jobs           = {},
		_pump_started   = false,
		_step_fn        = opts.step_fn,
		_wrap_fn        = opts.wrap_fn,
		_terminate_fn   = opts.terminate_fn,
		_max_pollable_timeout_s = opts.max_pollable_timeout_s or DEFAULT_MAX_POLLABLE_TIMEOUT_S,
	}, Driver)

	return self
end

function Driver:label()
	return self._label
end

function Driver:controller()
	return self._controller
end

function Driver:is_closed()
	return self._closed
end

function Driver:why()
	return self._close_reason
end

function Driver:_signal_changed()
	self._poke_pending = true
	notify_waitset(self._state_waiters, 'state')
end

--- Wake the pump.  Used when new work was queued into cqueues, and by tests.
function Driver:poke()
	self:_signal_changed()
end

function Driver:terminate(reason)
	if self._closed then return true end

	self._closed = true
	self._close_reason = reason or 'closed'

	local term = self._terminate_fn
	if term then safe.pcall(term, self._controller, self._close_reason) end

	for job in pairs(self._jobs) do
		job.abandoned = true
		job.abort_reason = self._close_reason
		job.phase = 'abandoned'
		notify_waitset(self._job_waiters, job)
	end

	self:_signal_changed()
	return true
end

local function step_return(ok, a, b, ...)
	if not ok then
		return nil, tostring_error(a)
	end

	if a == nil or a == false then
		if is_timeout_error(b) then
			-- A spurious readiness hint should not kill the bridge.
			return true, nil
		end
		return nil, b or 'cqueues step failed', ...
	end

	return true, nil
end

function Driver:_step_controller_now()
	local controller = self._controller
	if not controller then return nil, 'driver has no cqueues controller' end

	local step_fn = self._step_fn
	return step_return(safe.pcall(function ()
		if step_fn then return step_fn(controller, 0) end
		return controller:step(0)
	end))
end

function Driver:step_controller_now()
	return self:_step_controller_now()
end

function Driver:_step_pollable_now(pollable, step_fn)
	if self._closed then return nil, self._close_reason or 'closed' end

	return step_return(safe.pcall(function ()
		if step_fn then return step_fn(pollable, 0) end
		return pollable:step(0)
	end))
end

function Driver:step_pollable_now(pollable, step_fn)
	return self:_step_pollable_now(pollable, step_fn)
end

local function token2(tokens)
	return {
		unlink = function ()
			for i = 1, #tokens do
				local t = tokens[i]
				if t and t.unlink then t:unlink() end
				tokens[i] = nil
			end
			return false
		end,
	}
end

--- Wait until a cqueues-style pollable should be stepped.
---
--- Implemented with waitable2 because readiness is only a hint: after any fd,
--- timer, or explicit state wake, the operation reports that the pollable should
--- be stepped by its owner.
---
--- Returns: reason, err
---   reason: 'fd' | 'timeout' | 'poke'
---   err:    non-nil only when the driver is closed before readiness
function Driver:pollable_ready_op(pollable, opts)
	opts = opts or {}

	return op.guard(function ()
		assert(type(pollable) == 'table' or type(pollable) == 'userdata',
			'pollable_ready_op: pollable object required')

		local wake_reason

		local function compute_interest()
			if self._closed then
				return true, nil, self._close_reason or 'closed'
			end

			if self._poke_pending then
				self._poke_pending = false
				return true, 'poke', nil
			end

			local timeout
			if type(pollable.timeout) == 'function' then
				timeout = pollable:timeout()
			end
			if type(timeout) == 'number' and timeout <= 0 then
				return true, 'timeout', nil
			end
			if type(timeout) ~= 'number'
				or timeout ~= timeout
				or timeout == math.huge
				or timeout == -math.huge
			then
				timeout = nil
			elseif timeout > self._max_pollable_timeout_s then
				timeout = self._max_pollable_timeout_s
			end

			local fd
			if type(pollable.pollfd) == 'function' then
				fd = pollable:pollfd()
			end

			local rd, wr = false, false
			if fd ~= nil then
				local events = 'r'
				if type(pollable.events) == 'function' then
					events = pollable:events()
				end
				rd, wr = event_wants(events)
			end

			return false, {
				fd = fd,
				rd = rd,
				wr = wr,
				timeout = timeout,
				has_fd_interest = fd ~= nil and (rd or wr),
				state = true,
			}
		end

		local function probe_step()
			return compute_interest()
		end

		local function run_step()
			if wake_reason ~= nil then
				local r = wake_reason
				wake_reason = nil
				if self._closed then return true, nil, self._close_reason or 'closed' end
				return true, r, nil
			end
			return compute_interest()
		end

		local function register(task, waker, want)
			local tokens = {}
			local active = true

			local function make_wake(reason)
				return {
					run = function ()
						if not active then return end
						wake_reason = reason
						active = false
						task:run()
					end,
				}
			end

			if type(want) == 'table' then
				if want.fd ~= nil then
					if want.rd then
						tokens[#tokens + 1] = poller.get():wait(want.fd, 'rd', make_wake('fd'))
					end
					if want.wr then
						tokens[#tokens + 1] = poller.get():wait(want.fd, 'wr', make_wake('fd'))
					end
				end

				-- Fibers scheduler timers are wake-only and cannot be unlinked from
				-- the wheel. When an fd wait is already armed, fd readiness/pokes
				-- provide progress; adding an uncancellable timeout on every pump
				-- iteration can retain many stale timer tasks under active traffic.
				if not want.has_fd_interest and type(want.timeout) == 'number' and want.timeout > 0 then
					waker:after(want.timeout, make_wake('timeout'))
				end
			end

			tokens[#tokens + 1] = self._state_waiters:add('state', make_wake('poke'))

			return {
				unlink = function ()
					active = false
					return token2(tokens):unlink()
				end,
			}
		end

		return wait.waitable2(register, probe_step, run_step)
	end)
end

M.pollable_ready_op = function (driver, pollable, opts)
	return driver:pollable_ready_op(pollable, opts)
end

--- Wait until a pollable is ready, then call step(0).
function Driver:pollable_step_op(pollable, step_fn)
	return self:pollable_ready_op(pollable):wrap(function (reason, err)
		if reason == nil then return nil, err end
		return self:_step_pollable_now(pollable, step_fn)
	end)
end

function Driver:_complete_job(job, ok, results_or_err)
	if job.done or job.abandoned then return end

	job.done = true
	job.phase = 'done'
	job.ok = ok
	if ok then job.results = results_or_err or pack() else job.err = results_or_err end

	self._jobs[job] = nil
	notify_waitset(self._job_waiters, job)
	self:_signal_changed()
end

function Driver:_abandon_job(job, reason)
	if job.done or job.abandoned then return end

	local abort_reason = reason or 'aborted'
	local phase = job.phase or 'queued'

	job.abandoned = true
	job.abort_reason = abort_reason
	job.phase = 'abandoned'
	self._jobs[job] = nil

	if phase == 'active' then
		local on_active_abort = job.on_active_abort
		if on_active_abort then
			safe.pcall(on_active_abort, abort_reason, job)
		else
			-- Once cqueues/lua-http work is active, a plain loss of interest is
			-- not enough.  If no narrower owner supplied an active-abort hook,
			-- the driver is the only safe owner boundary left.
			self:terminate(abort_reason)
		end
	else
		local on_abort = job.on_abort
		if on_abort then safe.pcall(on_abort, abort_reason, job) end
	end

	notify_waitset(self._job_waiters, job)
	self:_signal_changed()
end

function Driver:_start_job(label, fn, opts)
	opts = opts or {}
	assert(type(fn) == 'function', 'run_op expects a function')

	if self._closed then return nil, self._close_reason or 'closed' end

	local controller = self._controller
	if not controller then return nil, 'driver has no cqueues controller' end

	local job = {
		label = label or 'cqueues job',
		phase = 'queued',
		done = false,
		ok = nil,
		results = nil,
		err = nil,
		abandoned = false,
		abort_reason = nil,
		on_abort = opts.on_abort,
		on_active_abort = opts.on_active_abort,
	}

	self._jobs[job] = true

	local function body()
		if job.abandoned then return end
		job.phase = 'active'
		local ok, result = safe.xpcall(function ()
			return pack(fn())
		end, function (e, tb)
			return tb or tostring_error(e)
		end)

		if job.abandoned then return end

		if ok then
			self:_complete_job(job, true, result)
		else
			self:_complete_job(job, false, result or 'cqueues job failed')
		end
	end

	local ok, err = safe.pcall(function ()
		local wrap_fn = self._wrap_fn
		if wrap_fn then return wrap_fn(controller, body) end
		return controller:wrap(body)
	end)

	if not ok then
		self._jobs[job] = nil
		return nil, tostring_error(err)
	end

	self:_signal_changed()
	return job, nil
end

function Driver:_job_outcome_op(job)
	local function step()
		if job.done then
			if job.ok then
				local r = job.results or pack()
				return true, unpack(r, 1, r.n)
			end
			return true, nil, job.err or 'cqueues job failed'
		end

		if job.abandoned then return true, nil, job.abort_reason or 'aborted' end
		if self._closed then return true, nil, self._close_reason or 'closed' end

		return false
	end

	local function register(task)
		return self._job_waiters:add(job, task)
	end

	return wait.waitable(register, step, identity)
end

--- Run a cqueues coroutine operation and expose its result as a Fibers Op.
--- The function is executed inside the driver's cqueues controller.
function Driver:run_op(label, fn, opts)
	return op.guard(function ()
		local job, err = self:_start_job(label, fn, opts)
		if not job then return op.always(nil, err) end

		return self:_job_outcome_op(job):on_abort(function ()
			self:_abandon_job(job, 'aborted')
		end)
	end)
end

--- Pump the driver's own cqueues controller until terminated.
function Driver:run()
	while not self._closed do
		local ok, err = perform(self:pollable_step_op(self._controller, function ()
			return self:_step_controller_now()
		end))
		if ok == nil then
			self:terminate(err or 'cqueues pump failed')
			return nil, err
		end
	end
	return true, nil
end

function Driver:start(scope)
	assert(scope and scope.spawn, 'Driver:start expects a scope')
	if self._pump_started then return true, nil end
	self._pump_started = true

	local ok, err = scope:spawn(function (owning_scope)
		-- A scope that has already started may only have finalisers installed
		-- from code running inside that same scope. Driver:start may be called
		-- by setup work in a child scope, so the ownership finaliser is
		-- installed by the pump fibre itself.
		owning_scope:finally(function ()
			self:terminate('scope_finalised')
		end)

		return self:run()
	end)
	if not ok then
		self._pump_started = false
		return nil, err
	end

	return true, nil
end

M.Driver = Driver
M.DEFAULT_MAX_POLLABLE_TIMEOUT_S = DEFAULT_MAX_POLLABLE_TIMEOUT_S

return M
