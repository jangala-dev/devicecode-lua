-- services/update/service.lua
--
-- Top-level update service coordinator.
--
-- The service owns service lifecycle, config watch, generation replacement,
-- manager endpoint binding, service model, publisher, and accepted active
-- update work. Generation-local update policy and projections live in
-- services.update.generation.

local fibers       = require 'fibers'
local mailbox      = require 'fibers.mailbox'
local scoped_work  = require 'devicecode.support.scoped_work'
local queue        = require 'devicecode.support.queue'
local bus_cleanup  = require 'devicecode.support.bus_cleanup'
local config_watch   = require 'devicecode.support.config_watch'
local service_events = require 'devicecode.support.service_events'
local service_base   = require 'devicecode.service_base'
local cap_deps_mod   = require 'devicecode.support.capability_dependencies'

local model_mod     = require 'services.update.model'
local config_mod    = require 'services.update.config'
local events        = require 'services.update.events'
local generation    = require 'services.update.generation'
local publisher     = require 'services.update.publisher'
local projection    = require 'services.update.projection'
local topics        = require 'services.update.topics'
local job_store_memory = require 'services.update.job_store_memory'
local control_store_jobs = require 'services.update.job_store_control_store'
local job_runtime_mod = require 'services.update.job_runtime'
local active_runtime = require 'services.update.active_runtime'
local observe_mod = require 'services.update.observe'
local component_watch = require 'services.update.component_watch'
local artifact_store_bus = require 'services.update.artifacts.store_bus'
local component_backend_mod = require 'services.update.backends.component'
local router_backend_mod = require 'services.update.backends.router'

local M = {}

local Service = {}
Service.__index = Service

local DEFAULT_DONE_QUEUE = 32

local function copy(v)
	return model_mod.deep_copy(v)
end

local function config_from_value(value, opts)
	local raw, rev = config_mod.extract_payload(value)
	return config_mod.normalise(raw or {}, {
		rev = rev,
		service_id = opts and opts.service_id or 'update',
	})
end

local function update_model_state(self, state, reason)
	local ready = state == 'running'
	self._model:update(function (s)
		s.state = state
		s.ready = ready
		s.reason = reason
		return s
	end)

	if self._svc and type(self._svc.status) == 'function' then
		local extra = { ready = ready }
		if reason ~= nil then extra.reason = reason end
		if self._deps and type(self._deps.snapshot) == 'function' then
			extra.dependencies = self._deps:snapshot()
		end
		self._svc:status(state, extra)
	end
end

local function apply_generation_snapshot(self, snapshot)
	self._model:update(function (s)
		s.generation = snapshot.generation or s.generation
		s.config = snapshot.config or s.config
		s.active = {
			generation = snapshot.generation,
			state = snapshot.state or 'running',
		}
		if self._jobs then
			s.jobs = self._jobs:snapshot()
		else
			s.jobs = snapshot.jobs or s.jobs
		end
		s.ingest = snapshot.ingest or s.ingest
		-- Active update work is service-owned. A generation snapshot may carry
		-- the current service-owned active snapshot for projection, but service
		-- completion handling remains authoritative.
		s.update_active = snapshot.update_active
		return s
	end)
end

local function clear_generation_snapshot(self)
	self._model:update(function (s)
		s.active = nil
		s.update_active = nil
		return s
	end)
end

local function make_generation_identity(self, generation_id)
	return {
		kind       = 'generation_done',
		service_id = self._service_id,
		generation = generation_id,
	}
end

local function default_generation_runner(scope, params)
	return generation.run(scope, params)
end

local function close_active_manager_route(active, reason)
	if active and active.manager_tx then
		active.manager_tx:close(reason or 'generation_route_closed')
	end
	if active and active.service_tx then
		active.service_tx:close(reason or 'generation_route_closed')
	end
end

local function cancel_active_generation(self, reason)
	local active = self._current_generation
	if not active then return end

	active.state = 'replacing'
	close_active_manager_route(active, reason or 'generation_replaced')

	if active.handle and active.handle.cancel then
		active.handle:cancel(reason or 'generation_replaced')
	end
end


local function active_snapshot(self)
	if not self._active_component or type(self._active_component.snapshot) ~= 'function' then
		return nil
	end
	local snap = self._active_component:snapshot()
	return snap and snap.active or nil
end

local function route_generation_event(self, ev, label)
	local active = self._current_generation
	if not active or active.state ~= 'running' or not active.route_port then
		return false, 'generation_not_ready'
	end
	return active.route_port:emit_required(ev, label or 'update_generation_route_event_failed')
end

local function start_generation(self, cfg, reason)
	local generation_id = self._next_generation
	self._next_generation = generation_id + 1

	local runner = self._generation_runner or default_generation_runner
	local manager_tx, manager_rx = mailbox.new(self._manager_route_queue_len or 32, {
		full = 'reject_newest',
	})
	local service_tx, service_rx = mailbox.new(self._generation_service_queue_len or 16, {
		full = 'reject_newest',
	})
	local route_port = service_events.port(service_tx, {
		service_id = self._service_id,
		source = 'update_service',
		source_id = self._service_id,
		generation = generation_id,
	}, {
		mark_route_events = true,
		label = 'update_generation_route_event_admission_failed',
	})
	local generation_events_port = service_events.port(self._done_tx, {
		service_id = self._service_id,
		source = 'update_generation_scope',
		source_id = tostring(generation_id),
		generation = generation_id,
	}, {
		label = 'update_generation_completion_report_failed',
	})

	local handle, err = scoped_work.start {
		lifetime_scope = self._scope,
		reaper_scope   = self._scope,
		report_scope   = self._scope,

		identity = make_generation_identity(self, generation_id),

		run = function (gen_scope)
			gen_scope:finally(function (_, status, primary)
				local close_reason = primary or status or 'generation_closed'
				manager_tx:close(close_reason)
				service_tx:close(close_reason)
			end)

			return runner(gen_scope, {
				service_id = self._service_id,
				generation = generation_id,
				config = cfg,
				reason = reason,
				jobs = self._jobs,
				manager_rx = manager_rx,
				service_rx = service_rx,
				active_snapshot = active_snapshot(self),
				artifact_store = self._artifact_store,
				events_tx = self._done_tx,
				done_queue_len = self._generation_done_queue_len,
			})
		end,

		report = service_events.reporter(
			generation_events_port,
			'update_generation_completion_report_failed'
		),
	}

	if not handle then
		local reason2 = err or 'generation_start_failed'
		manager_tx:close(reason2)
		service_tx:close(reason2)
		return nil, err
	end

	if self._jobs and type(self._jobs.set_current_generation) == 'function' then
		self._jobs:set_current_generation(generation_id)
	end

	self._current_generation = {
		generation = generation_id,
		config = cfg,
		handle = handle,
		manager_tx = manager_tx,
		manager_rx = manager_rx,
		service_tx = service_tx,
		service_rx = service_rx,
		route_port = route_port,
		state = 'running',
	}

	self._model:update(function (s)
		s.generation = generation_id
		s.config = config_mod.summary(cfg)
		s.active = {
			generation = generation_id,
			state = 'running',
		}
		s.update_active = active_snapshot(self)
		return s
	end)
	update_model_state(self, 'running')

	return handle, nil
end

local reconcile_runtime_components

local function replace_generation(self, cfg, reason)
	cancel_active_generation(self, reason or 'generation_replaced')
	return start_generation(self, cfg, reason or 'config_changed')
end

local function apply_config(self, payload, reason)
	local cfg, err = config_from_value(payload, { service_id = self._service_id })
	if not cfg then
		update_model_state(self, 'degraded', err or 'invalid_config')
		return true, err
	end

	if self._config and config_mod.material_equal(self._config, cfg) then
		return true, nil
	end

	self._config = cfg
	self._model:update(function (s)
		s.config = config_mod.summary(cfg)
		return s
	end)

	if self._jobs == nil then
		return reconcile_runtime_components(self, reason or 'config_changed')
	end

	local ok, start_err = replace_generation(self, cfg, reason or 'config_changed')
	if not ok then
		update_model_state(self, 'failed', start_err or 'generation_start_failed')
		error(start_err or 'generation_start_failed', 0)
	end

	return true, nil
end

local function handle_generation_snapshot(self, ev)
	if ev.service_id ~= self._service_id then return end

	local active = self._current_generation
	if not active or active.generation ~= ev.generation then
		return
	end

	active.last_snapshot = ev.snapshot
	apply_generation_snapshot(self, ev.snapshot or {})
end

local function handle_generation_done(self, ev)
	if ev.service_id ~= self._service_id then
		return
	end

	local active = self._current_generation
	if not active or active.generation ~= ev.generation then
		return
	end

	self._current_generation = nil
	clear_generation_snapshot(self)

	if active.state == 'replacing' and ev.status == 'cancelled' then
		return
	end

	if ev.status == 'ok' then
		update_model_state(self, 'stopped', 'generation_completed')
		self._complete = true
		return
	end

	if ev.status == 'cancelled' then
		update_model_state(self, 'stopped', ev.primary or 'generation_cancelled')
		self._complete = true
		return
	end

	local reason = ev.primary or 'generation_failed'
	update_model_state(self, 'failed', reason)
	error('update generation failed: ' .. tostring(reason), 0)
end

local function fail_manager_request(req, reason)
	local owner = require('devicecode.support.request_owner').new(req)
	local ok, err = owner:fail_once(reason)
	if ok ~= true then error(err or tostring(reason or 'manager_request_failed'), 0) end
end

local function handle_manager_without_generation(_, req)
	fail_manager_request(req, 'generation_not_ready')
end

local function route_manager_request(self, req, method)
	local active = self._current_generation
	local dependency_unavailable = self._job_store_dependency_required
		and self._deps
		and not self._deps:available('job_store')

	-- Preserve the generation-private route for status requests once a generation
	-- is running and dependencies are effectively available.  If a required
	-- dependency has disappeared, status is still safe for the shell to answer
	-- directly while mutating requests are rejected below.
	if method == 'status' and dependency_unavailable and req and type(req.reply) == 'function' then
		req:reply({ ok = true, snapshot = self._model:snapshot() })
		return
	end

	-- Before a generation is admitted, status is the one safe manager method the
	-- shell can answer directly, including while waiting for the job store.
	if not active or active.state ~= 'running' or active.manager_tx == nil then
		if method == 'status' and req and type(req.reply) == 'function' then
			req:reply({ ok = true, snapshot = self._model:snapshot() })
			return
		end

		if dependency_unavailable then
			fail_manager_request(req, 'job_store_unavailable')
			return
		end
		if self._jobs == nil then
			fail_manager_request(req, self._job_store_dependency_required and 'job_store_unavailable' or 'job_runtime_not_ready')
			return
		end
		if self._job_runtime_ready ~= true then
			fail_manager_request(req, 'job_runtime_not_ready')
			return
		end
		handle_manager_without_generation(self, req)
		return
	end

	if dependency_unavailable then
		fail_manager_request(req, 'job_store_unavailable')
		return
	end

	if method ~= nil and type(req) == 'table' then
		req._update_method = method
	end

	local ok, err = queue.try_admit_now(active.manager_tx, req)
	if ok == true then
		return
	end

	fail_manager_request(req, err or 'generation_busy')
end

local function update_active_projection(self)
	self._model:update(function (s)
		s.update_active = active_snapshot(self)
		return s
	end)
end

local function update_service_jobs_projection(self)
	if not self._jobs then return end
	self._model:update(function (s)
		s.jobs = self._jobs:snapshot()
		return s
	end)
end

local function consider_active_jobs(self)
	if not self._active_component or type(self._active_component.consider_jobs) ~= 'function' then
		return false, 'not_ready'
	end

	local ok, err = self._active_component:consider_jobs()
	update_active_projection(self)

	if ok == nil and err ~= 'slot_busy' and err ~= 'no_active_intent' and err ~= 'not_ready' then
		update_model_state(self, 'failed', err)
		error('update active runtime launch failed: ' .. tostring(err), 0)
	end

	return ok, err
end

local handle_dependency_changed
local stop_job_runtime
local stop_runtime_dependents
local update_dependencies_projection
local set_waiting_for_job_store
local ensure_runtime_dependents
local reconcile_runtime_components

local function handle_job_runtime_changed(self, ev)
	self._jobs_seen = ev.version
	if self._jobs and self._jobs:ready() and not self._job_runtime_ready then
		self._job_runtime_ready = true
		update_service_jobs_projection(self)
		local ok, err = reconcile_runtime_components(self, 'job_runtime_ready')
		if ok ~= true then
			update_model_state(self, 'failed', err or 'runtime_dependents_start_failed')
			error(err or 'runtime_dependents_start_failed', 0)
		end
	else
		update_service_jobs_projection(self)
	end
	if self._current_generation then
		apply_generation_snapshot(self, self._current_generation.last_snapshot or {
			generation = self._current_generation.generation,
			config = config_mod.summary(self._current_generation.config),
			state = self._current_generation.state,
			update_active = active_snapshot(self),
		})
	end
	consider_active_jobs(self)
end

local function handle_active_runtime_changed(self, ev)
	update_active_projection(self)
	update_service_jobs_projection(self)
	if self._current_generation then
		apply_generation_snapshot(self, self._current_generation.last_snapshot or {
			generation = self._current_generation.generation,
			config = config_mod.summary(self._current_generation.config),
			state = self._current_generation.state,
			update_active = active_snapshot(self),
		})
		if self._current_generation.state == 'running' then
			local ok, err = route_generation_event(self, {
				kind = 'service_active_snapshot',
				snapshot = active_snapshot(self),
				reason = ev and ev.reason or 'active_runtime_changed',
			}, 'update_generation_active_snapshot_admission_failed')
			if ok ~= true then
				update_model_state(self, 'failed', err or 'active_snapshot_route_failed')
				error(err or 'active_snapshot_route_failed', 0)
			end
		end
	end
end

local function reduce_event(self, ev)
	if ev.kind == 'generation_done_queue_closed' then
		error('update generation completion queue closed', 0)
	end

	if ev.kind == 'config_watch_closed' then
		update_model_state(self, 'degraded', 'config_watch_closed')
		return
	end

	if ev.kind == 'config_replay_done' then
		return
	end

	if ev.kind == 'config_removed' then
		update_model_state(self, 'degraded', 'config_removed')
		return
	end

	if ev.kind == 'config_changed' then
		apply_config(self, ev.payload, 'config_changed')
		return
	end

	if ev.kind == 'job_runtime_model_closed' then
		local reason = ev.reason or 'job_runtime_model_closed'
		if self._deps and self._deps:classify_call_failure('job_store', ev, reason) == 'route_missing' then
			stop_runtime_dependents(self, 'job_store_unavailable')
			stop_job_runtime(self, 'job_store_unavailable')
			update_dependencies_projection(self)
			set_waiting_for_job_store(self, 'job_store_unavailable')
			return
		end

		-- changed_op() close notifications can arrive before the scoped-work
		-- component_done event that carries the authoritative worker failure. While
		-- the job runtime has not become ready, defer policy to that completion.
		-- Clear the closed runtime model as an event source so the coordinator does
		-- not spin on an already-closed changed_op() and starve manager/dependency
		-- events.
		if self._suppress_dependents_reason or reason == 'job_store_unavailable' then
			return
		end

		if self._job_store_dependency_required and self._job_runtime_ready ~= true then
			self._jobs = nil
			self._jobs_seen = nil
			self._job_runtime_ready = false
			return
		end

		update_model_state(self, 'failed', reason)
		error(reason, 0)
	end

	if ev.kind == 'job_runtime_changed' then
		handle_job_runtime_changed(self, ev)
		return
	end

	if ev.kind == 'manager_closed' then
		update_model_state(self, 'degraded', 'manager_closed')
		return
	end

	if ev.kind == 'manager_request' then
		route_manager_request(self, ev.request, ev.method)
		return
	end

	if ev.kind == 'capability_dependency_changed' or ev.kind == 'capability_dependency_closed' then
		handle_dependency_changed(self, ev)
		return
	end

	if ev.kind == 'active_runtime_changed' then
		handle_active_runtime_changed(self, ev)
		return
	end

	if ev.kind == 'generation_snapshot' then
		handle_generation_snapshot(self, ev)
		return
	end

	if ev.kind == 'generation_done' then
		handle_generation_done(self, ev)
		return
	end

	if ev.kind == 'component_done' and ev.component == 'job_runtime' then
		if ev.status == 'failed' then
			local reason = ev.primary or 'job_runtime_failed'
			if self._deps and self._deps:classify_call_failure('job_store', ev, reason) == 'route_missing' then
				stop_runtime_dependents(self, 'job_store_unavailable')
				stop_job_runtime(self, 'job_store_unavailable')
				update_dependencies_projection(self)
				set_waiting_for_job_store(self, 'job_store_unavailable')
				return
			end
			update_model_state(self, 'failed', reason)
			error('update job runtime failed: ' .. tostring(reason), 0)
		end
		if ev.status == 'cancelled' and (self._suppress_dependents_reason or ev.primary == 'job_store_unavailable') then
			return
		end
		if not self._complete then
			update_model_state(self, 'degraded', ev.primary or ev.status or 'job_runtime_stopped')
		end
		return
	end

	if ev.kind == 'component_done' and ev.component == 'active_runtime' then
		if ev.status == 'cancelled' and (self._suppress_dependents_reason or ev.primary == 'job_store_unavailable') then
			return
		end
		self._active_component = nil
		if ev.status == 'failed' then
			local reason = ev.primary or 'active_runtime_failed'
			update_model_state(self, 'failed', reason)
			error('update active runtime failed: ' .. tostring(reason), 0)
		end
		if not self._complete then
			update_model_state(self, 'degraded', ev.primary or ev.status or 'active_runtime_stopped')
		end
		return
	end

	if ev.kind == 'component_done' and ev.component == 'component_watch' then
		if ev.status == 'cancelled' and (self._suppress_dependents_reason or ev.primary == 'job_store_unavailable') then
			return
		end
		self._component_watch = nil
		if ev.status == 'failed' then
			local reason = ev.primary or 'component_watch_failed'
			update_model_state(self, 'failed', reason)
			error('update component watch failed: ' .. tostring(reason), 0)
		end
		if not self._complete then
			update_model_state(self, 'degraded', ev.primary or ev.status or 'component_watch_stopped')
		end
		return
	end

	if ev.kind == 'component_done' and ev.component == 'publisher' then
		self.publisher = nil
		self._publisher = nil
		if ev.status == 'failed' then
			local reason = ev.primary or 'publisher_failed'
			update_model_state(self, 'failed', reason)
			error('update publisher failed: ' .. tostring(reason), 0)
		end
		if not self._complete then
			update_model_state(self, 'degraded', ev.primary or ev.status or 'publisher_stopped')
		end
		return
	end

	error('update.service: unknown event kind: ' .. tostring(ev.kind), 0)
end

local function coordinator_loop(self)
	while not self._complete do
		local ev = fibers.perform(events.next_service_event_op(self))
		reduce_event(self, ev)
	end

	if self.publisher then
		if self.publisher.cancel then
			self.publisher:cancel('service_complete')
		elseif self.publisher.stop then
			self.publisher:stop('service_complete')
		end
	end
	if self._jobs and self._jobs.cancel then
		self._jobs:cancel('service_complete')
	end
	if self._active_component and self._active_component.cancel then
		self._active_component:cancel('service_complete')
	end
	if self._component_watch and self._component_watch.cancel then
		self._component_watch:cancel('service_complete')
	end
	if self._active_scope and self._active_scope.cancel then
		self._active_scope:cancel('service_complete')
	end

	return {
		role = 'update_service',
		service_id = self._service_id,
		snapshot = self._model:snapshot(),
	}
end

local function start_publisher_component(self, conn, model)
	if not conn then return nil, nil end

	local handle, err = scoped_work.start {
		lifetime_scope = self._scope,
		reaper_scope   = self._scope,
		report_scope   = self._scope,

		identity = {
			kind       = 'component_done',
			service_id = self._service_id,
			component  = 'publisher',
		},

		run = function (component_scope)
			return publisher.run(component_scope, {
				conn = conn,
				model = model,
			})
		end,

		report = service_events.reporter(
			service_events.port(self._done_tx, {
				service_id = self._service_id,
				source = 'update_publisher',
				source_id = 'publisher',
			}, {
				label = 'update_publisher_completion_report_failed',
			}),
			'update_publisher_completion_report_failed'
		),
	}

	if not handle then
		return nil, err
	end

	return handle, nil
end

local function bind_manager(scope, conn, opts)
	if not conn then return nil, nil end
	if opts and opts.bind_manager == false then return nil, nil end

	local methods = topics.manager_methods()
	local tx, rx = mailbox.new((opts and opts.manager_queue_len) or 16, {
		full = 'reject_newest',
	})
	local endpoints = {}

	local function cleanup_bound()
		for _, ep in pairs(endpoints) do
			bus_cleanup.unbind(conn, ep)
		end
		if tx and type(tx.close) == 'function' then tx:close('manager endpoints closed') end
	end

	for _, method in ipairs(methods) do
		local ep, err = bus_cleanup.bind(conn, topics.update_manager_rpc(method), {
			queue_len = opts and opts.manager_queue_len or 16,
		})
		if not ep then
			cleanup_bound()
			return nil, err
		end
		endpoints[method] = ep
	end

	local ingest_methods = topics.ingest_methods()
	for _, method in ipairs(ingest_methods) do
		local ep, err = bus_cleanup.bind(conn, topics.artifact_ingest_rpc(method), {
			queue_len = opts and opts.ingest_queue_len or opts and opts.manager_queue_len or 16,
		})
		if not ep then
			cleanup_bound()
			return nil, err
		end
		endpoints['ingest:' .. method] = ep
	end

	scope:finally(cleanup_bound)

	for key, ep in pairs(endpoints) do
		local method = key
		local is_ingest = false
		if type(key) == 'string' and key:sub(1, 7) == 'ingest:' then
			method = key:sub(8)
			is_ingest = true
		end

		local loop_method = method
		local loop_is_ingest = is_ingest
		local loop_ep = ep
		local handle, spawn_err = scoped_work.start {
			lifetime_scope = scope,
			reaper_scope   = scope,
			report_scope   = scope,

			identity = {
				kind = 'manager_endpoint_loop_done',
				method = loop_method,
				is_ingest = loop_is_ingest,
			},

			run = function (ep_scope)
				-- The endpoint loop is the first owner that is guaranteed to be
				-- joined during service shutdown.  Unbind here as well as in the
				-- parent finaliser so that a restarted update service cannot race
				-- stale manager endpoints left registered on the bus.
				ep_scope:finally(function ()
					bus_cleanup.unbind(conn, loop_ep)
				end)

				while true do
					local req = fibers.perform(loop_ep:recv_op())
					if req == nil then
						queue.try_admit_now(tx, { closed = true, method = loop_method, reason = 'endpoint_closed' })
						return { role = 'update_manager_endpoint', method = loop_method, reason = 'endpoint_closed' }
					end
					local routed_method = loop_is_ingest and ('ingest-' .. loop_method) or loop_method
					local ok_admit, admit_err = queue.try_admit_now(tx, {
						method = routed_method,
						request = req,
					})
					if ok_admit ~= true then
						fail_manager_request(req, admit_err or 'manager_busy')
					end
				end
			end,
		}
		if not handle then
			cleanup_bound()
			return nil, spawn_err or 'manager_endpoint_loop_start_failed'
		end
	end

	return rx, nil
end

local function open_config_watch(scope, conn, opts)
	opts = opts or {}
	local watch = opts.config_watch or opts.config_feed
	local owns_watch = false

	if watch == nil and opts.config_rx ~= nil then
		return nil, nil
	end

	if watch == nil and opts.watch_config ~= false then
		if not conn then return nil, nil end

		local err
		watch, err = config_watch.open(conn, opts.name or opts.service_id or 'update', {
			topic = opts.config_topic or topics.config(),
			queue_len = opts.config_queue_len or 8,
			full = 'reject_newest',
			changed_kind = 'config_changed',
			closed_kind = 'config_watch_closed',
		})
		if not watch then return nil, err end
		owns_watch = true
	end

	if owns_watch then
		scope:finally(function ()
			if type(watch.close) == 'function' then
				watch:close()
			end
		end)
	end

	return watch, nil
end


local function job_store_dependency_required(params)
	if params.job_store ~= nil then return false end
	if params.job_store_kind == 'memory' or params.memory_job_store == true then return false end
	return params.conn ~= nil
end

update_dependencies_projection = function(self)
	if not self._deps then return end
	self._model:update(function (s)
		s.dependencies = self._deps:snapshot()
		return s
	end)
end

local function make_job_store(params)
	if params.job_store ~= nil then return params.job_store end
	if params.job_store_kind == 'memory' or params.memory_job_store == true then
		return job_store_memory.new(params.initial_jobs)
	end
	return control_store_jobs.new(params.conn, {
		id = params.job_store_id or params.control_store_id or 'update',
		prefix = params.job_store_prefix or 'update-job-',
		call_opts = params.job_store_call_opts,
	})
end

local function dependency_effectively_available(self, key)
	if not self._deps then return true end
	return self._deps:available(key)
end

set_waiting_for_job_store = function(self, reason)
	reason = reason or 'job_store_unavailable'
	update_dependencies_projection(self)
	update_model_state(self, 'waiting_for_job_store', reason)
	return true, nil
end

stop_job_runtime = function(self, reason)
	reason = reason or 'job_store_unavailable'
	local jobs = self._jobs
	self._jobs = nil
	self._jobs_seen = nil
	self._job_runtime_ready = false
	if jobs and type(jobs.cancel) == 'function' then
		jobs:cancel(reason)
	end
	update_service_jobs_projection(self)
	return true, nil
end

stop_runtime_dependents = function(self, reason)
	reason = reason or 'job_store_unavailable'
	self._suppress_dependents_reason = reason
	cancel_active_generation(self, reason)
	if self._current_generation and self._current_generation.state == 'replacing' then
		self._current_generation = nil
		clear_generation_snapshot(self)
	end
	if self._active_component and self._active_component.cancel then self._active_component:cancel(reason or 'job_store_unavailable') end
	if self._component_watch and self._component_watch.cancel then self._component_watch:cancel(reason or 'job_store_unavailable') end
	if self._active_scope and self._active_scope.cancel then self._active_scope:cancel(reason or 'job_store_unavailable') end
	self._active_scope = nil
	self._active_component = nil
	self._active_runtime = nil
	self._component_watch = nil
end

local function ensure_job_runtime(self, reason)
	if self._jobs ~= nil then return true, nil end
	self._suppress_dependents_reason = nil
	if self._job_store_dependency_required and not dependency_effectively_available(self, 'job_store') then
		return set_waiting_for_job_store(self, 'job_store_unavailable')
	end

	local params = self._params or {}
	local job_store = self._job_store or make_job_store(params)
	self._job_store = job_store

	local jobs, jobs_err = job_runtime_mod.start(self._scope, {
		service_id = self._service_id,
		store = job_store,
		initial_jobs = params.initial_jobs,
		done_tx = self._done_tx,
		queue_len = params.job_runtime_queue_len,
	})
	if not jobs then
		return nil, jobs_err or 'update_job_repository_start_failed'
	end

	self._jobs = jobs
	self._jobs_seen = jobs:version()
	self._job_runtime_ready = jobs:ready()
	update_dependencies_projection(self)
	update_service_jobs_projection(self)
	return true, nil
end

local function ensure_active_runtime(self, reason)
	local params = self._params or {}
	local adoption = self._jobs:adoption() or {}

	if self._active_component and type(self._active_component.update_adoption) == 'function' then
		self._active_component:update_adoption(adoption)
	end

	if self._active_component ~= nil then return true, nil end

	local active_scope, active_scope_err = self._scope:child()
	if not active_scope then
		return nil, active_scope_err or 'update_active_runtime_scope_create_failed'
	end
	self._active_scope = active_scope

	local active_component, active_component_err = active_runtime.start_component(active_scope, {
		service_id = self._service_id,
		done_tx = self._done_tx,
		work_scope = active_scope,
		queue_len = params.active_runtime_queue_len,
		jobs = self._jobs,
		backend = self._backend,
		observer = self._component_observer,
		adoption = adoption,
	})
	if not active_component then
		active_scope:cancel(active_component_err or 'update_active_runtime_start_failed')
		self._active_scope = nil
		return nil, active_component_err or 'update_active_runtime_start_failed'
	end
	self._active_component = active_component
	self._active_runtime = active_component:state()
	return true, nil
end

local function ensure_component_watch(self, reason)
	local params = self._params or {}
	if self._component_watch ~= nil or params.conn == nil or params.watch_components == false then
		return true, nil
	end

	local cw_port = service_events.port(self._done_tx, {
		service_id = self._service_id,
		source = 'update_component_watch',
		source_id = 'component_watch',
	}, {
		label = 'update_component_watch_completion_report_failed',
	})
	local cwh, cwerr = component_watch.start(self._scope, {
		service_id = self._service_id,
		conn = params.conn,
		observer = self._component_observer,
		config = self._config,
		queue_len = params.component_watch_queue_len,
		report = service_events.reporter(cw_port, 'update_component_watch_completion_report_failed'),
	})
	if not cwh then return nil, cwerr or 'update_component_watch_start_failed' end
	self._component_watch = cwh
	return true, nil
end

ensure_runtime_dependents = function(self, reason)
	if self._jobs == nil then return nil, 'job_runtime_not_ready' end
	if self._jobs.ready and not self._jobs:ready() then
		update_dependencies_projection(self)
		update_service_jobs_projection(self)
		update_model_state(self, 'starting', 'job_runtime_loading')
		return true, nil
	end

	local ok, err = ensure_active_runtime(self, reason or 'runtime_dependents')
	if ok ~= true then return nil, err end
	ok, err = ensure_component_watch(self, reason or 'runtime_dependents')
	if ok ~= true then return nil, err end

	update_dependencies_projection(self)
	update_service_jobs_projection(self)
	return true, nil
end

local function ensure_generation_running(self, reason)
	if self._config and self._current_generation == nil then
		local ok, err = start_generation(self, self._config, reason or 'initial')
		if not ok then return nil, err or 'generation_start_failed' end
	else
		update_model_state(self, 'running')
	end
	return true, nil
end

reconcile_runtime_components = function(self, reason)
	if self._job_store_dependency_required and not dependency_effectively_available(self, 'job_store') then
		stop_runtime_dependents(self, 'job_store_unavailable')
		stop_job_runtime(self, 'job_store_unavailable')
		return set_waiting_for_job_store(self, 'job_store_unavailable')
	end

	local ok, err = ensure_job_runtime(self, reason or 'runtime_reconcile')
	if ok ~= true then return nil, err end
	if self._job_runtime_ready ~= true then
		update_dependencies_projection(self)
		update_service_jobs_projection(self)
		update_model_state(self, 'starting', 'job_runtime_loading')
		return true, nil
	end

	ok, err = ensure_runtime_dependents(self, reason or 'job_runtime_ready')
	if ok ~= true then return nil, err end
	ok, err = ensure_generation_running(self, reason or 'runtime_ready')
	if ok ~= true then return nil, err end
	consider_active_jobs(self)
	return true, nil
end

handle_dependency_changed = function(self, ev)
	update_dependencies_projection(self)
	if ev.key == 'job_store' then
		if dependency_effectively_available(self, 'job_store') then
			local ok, err = reconcile_runtime_components(self, 'job_store_available')
			if ok ~= true then
				update_model_state(self, 'failed', err or 'job_runtime_start_failed')
				error(err or 'job_runtime_start_failed', 0)
			end
		elseif self._job_store_dependency_required then
			-- Required durable storage disappeared or the status feed closed.  Keep
			-- the service shell and public status endpoint alive, but stop dependent
			-- generation/active work, cancel the durable job runtime, and reject new
			-- mutating manager requests until the dependency becomes effectively
			-- available and the runtime has reloaded from the store.
			stop_runtime_dependents(self, 'job_store_unavailable')
			stop_job_runtime(self, 'job_store_unavailable')
			set_waiting_for_job_store(self, 'job_store_unavailable')
		end
	end
end

function M.run(scope, params)
	if type(scope) ~= 'table' then
		error('update.service.run: scope required', 2)
	end
	params = params or {}
	if type(params) ~= 'table' then
		error('update.service.run: params table required', 2)
	end

	local service_id = params.service_id or params.name or 'update'
	local initial_cfg, cfg_err = config_from_value(params.config or {}, { service_id = service_id })
	if not initial_cfg then
		error('update.service: ' .. tostring(cfg_err), 2)
	end

	local initial = model_mod.service_initial(service_id, 0)
	initial.config = config_mod.summary(initial_cfg)

	local service_model = model_mod.new(initial, { label = 'update.service' })
	scope:finally(function (_, status, primary)
		service_model:terminate(primary or status or 'update service closed')
	end)

	local done_tx, done_rx = mailbox.new(params.done_queue_len or DEFAULT_DONE_QUEUE, {
		full = 'reject_newest',
	})
	scope:finally(function ()
		done_tx:close('update service closed')
	end)

	local manager_ep, merr = bind_manager(scope, params.conn, params)
	if merr then error(merr, 2) end

	local config_watch, werr = open_config_watch(scope, params.conn, params)
	if werr then error(werr, 2) end

	local deps
	local job_dep_required = job_store_dependency_required(params)
	if job_dep_required then
		local derr
		deps, derr = cap_deps_mod.open(params.conn, {
			{
				key = 'job_store',
				class = 'control-store',
				id = params.job_store_id or params.control_store_id or 'update',
				required = true,
			},
		}, {
			queue_len = params.dependency_queue_len or params.status_queue_len or 8,
			full = params.dependency_full or params.status_full or 'drop_oldest',
		})
		if not deps then error(derr or 'update dependency watcher failed', 2) end
		scope:finally(function (_, status, primary)
			deps:close(primary or status or 'update dependencies closed')
		end)
	end

	local job_store = make_job_store(params)

	local artifact_store = params.artifact_store
	if artifact_store == nil then
		artifact_store = artifact_store_bus.new(params.conn, {
			id = params.artifact_store_id or 'main',
			call_opts = params.artifact_store_call_opts,
		})
	end

	local component_observer = params.component_observer or observe_mod.new({
		service_id = service_id,
		components = initial_cfg.components or {},
	})
	scope:finally(function (_, status, primary)
		if component_observer and type(component_observer.terminate) == 'function' then
			component_observer:terminate(primary or status or 'update component observer closed')
		end
	end)

	local backend = params.backend
	if backend == nil then
		local component_backend = component_backend_mod.new({
			conn = params.conn,
			artifact_store = artifact_store,
			observer = component_observer,
			component = 'mcu',
		})
		backend = router_backend_mod.new({
			components = { mcu = component_backend },
			default = component_backend,
			commit_policy = 'no_duplicate',
		})
	end

	local self = setmetatable({
		_scope = scope,
		_service_id = service_id,
		_svc = params.svc,
		_model = service_model,
		_done_tx = done_tx,
		_done_rx = done_rx,
		done_rx = done_rx,
		_active_scope = nil,
		_active_component = nil,
		_active_runtime = nil,
		_manager_ep = manager_ep,
		manager_rx = manager_ep,
		config_watch = config_watch,
		config_rx = params.config_rx or config_watch,
		publisher = nil,
		_publisher = nil,
		pending = {},
		_config = initial_cfg,
		_current_generation = nil,
		_next_generation = params.generation or 1,
		_generation_runner = params.generation_runner,
		_jobs_seen = nil,
		_jobs = nil,
		_job_store = job_store,
		_job_store_dependency_required = job_dep_required,
		_deps = deps,
		_artifact_store = artifact_store,
		_component_observer = component_observer,
		_component_watch = nil,
		_backend = backend,
		_job_runtime_ready = false,
		_generation_done_queue_len = params.generation_done_queue_len,
		_manager_route_queue_len = params.manager_route_queue_len,
		_generation_service_queue_len = params.generation_service_queue_len,
		_complete = false,
		_params = params,
	}, Service)

	update_dependencies_projection(self)
	if job_dep_required and not deps:available('job_store') then
		update_model_state(self, 'waiting_for_job_store', 'job_store_unavailable')
	else
		update_model_state(self, 'starting', 'job_runtime_loading')
	end

	if params.conn and params.publish ~= false then
		local pub, perr = start_publisher_component(self, params.conn, service_model)
		if not pub then error(perr or 'update publisher start failed', 2) end
		self.publisher = pub
		self._publisher = pub
	end

	local ok, err = reconcile_runtime_components(self, 'initial')
	if ok ~= true then error(err or 'update runtime start failed', 2) end

	return coordinator_loop(self)
end

function M.start(conn, opts)
	opts = opts or {}
	local scope = fibers.current_scope()
	if not scope then
		error('update.start must be called inside a fiber', 2)
	end

	local svc = service_base.new(conn, {
		name = opts.name or 'update',
		env = opts.env,
		meta = opts.meta,
		announce = opts.announce,
	})

	svc:starting({ ready = false })

	local params = copy(opts)
	params.conn = conn
	params.name = opts.name or 'update'
	params.svc = svc

	M.run(scope, params)

	svc:stopped({ reason = 'returned' })
	error('update service returned unexpectedly', 0)
end

M.Service = Service

return M
