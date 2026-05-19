-- services/update/generation.lua
--
-- Generation lifetime composition and coordinator.
--
-- The service starts and replaces generations. This module keeps the
-- generation role narrow: it owns the generation scope, composes
-- generation-local owners, and reduces semantic events. It never calls back
-- into parent service state. Parent-visible changes are reported as events on
-- the supplied service event port.

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'

local model_mod         = require 'services.update.model'
local config_mod        = require 'services.update.config'
local manager_mod       = require 'services.update.manager'
local generation_events = require 'services.update.generation_events'
local observe_mod       = require 'services.update.observe'
local ingest_mod        = require 'services.update.ingest'
local bundled_mod       = require 'services.update.bundled'
local service_events    = require 'devicecode.support.service_events'

local M = {}

local DEFAULT_DONE_QUEUE = 32

local Generation = {}
Generation.__index = Generation

local function copy(v)
	return model_mod.deep_copy(v)
end

local function emit_generation_snapshot(self, snapshot)
	if not self._events then return true, nil end
	return self._events:emit_required({
		kind = 'generation_snapshot',
		snapshot = snapshot,
	}, 'update_generation_snapshot_report_failed')
end

local function update_generation_model(self)
	local jobs_ready = self._jobs == nil or type(self._jobs.ready) ~= 'function' or self._jobs:ready()
	local changed, err = self._model:update(function (s)
		s.state = jobs_ready and 'running' or 'starting'
		s.ready = jobs_ready
		s.reason = jobs_ready and nil or 'job_runtime_loading'
		s.jobs = self._jobs:snapshot()
		s.update_active = copy(self._active_snapshot)
		if self._observer then
			s.components = self._observer:snapshot()
		end
		if self._ingest then
			s.ingest = self._ingest:snapshot()
		end
		if self._bundled then
			s.bundled = self._bundled:snapshot()
		end
		return s
	end)
	if changed == nil then return nil, err or 'generation_model_update_failed' end
	if changed then
		local ok, eerr = emit_generation_snapshot(self, self._model:snapshot())
		if ok ~= true then return nil, eerr end
	end
	return true, nil
end

local function assert_update_generation_model(self)
	local ok, err = update_generation_model(self)
	if ok ~= true then error(err or 'update_generation_model_failed', 0) end
	return true
end

function M.initial_snapshot(params)
	params = params or {}
	local cfg = params.config or config_mod.default()
	return model_mod.generation_initial {
		service_id = params.service_id or 'update',
		generation = params.generation or 1,
		config = config_mod.summary(cfg),
		components = cfg.components or {},
		bundled = cfg.bundled or {},
	}
end

local function make_manager_context(self)
	return {
		scope = self._scope,
		request_root = self._request_root,
		service_id = self._service_id,
		generation = self._generation,
		config = self._config,
		done_tx = self._done_tx,
		jobs = self._jobs,
		manager_work = self._manager_work,
		observer = self._observer,
		ingest = self._ingest,
		artifact_store = self._artifact_store,
		active = copy(self._active_snapshot),
		snapshot = self._model:snapshot(),
	}
end

local function handle_manager_request(self, req)
	-- Manager requests are cheap coordinator events. Refresh the generation model
	-- from local state and service-provided projections before answering or
	-- admitting scoped request work.
	assert_update_generation_model(self)
	return manager_mod.handle_request(make_manager_context(self), req)
end

local function handle_manager_done(self, ev)
	local ok = manager_mod.handle_done(make_manager_context(self), ev)
	if ok then assert_update_generation_model(self) end
end

local function handle_service_active_snapshot(self, ev)
	self._active_snapshot = copy(ev.snapshot)
	assert_update_generation_model(self)
end

local function start_bundled_probes(self)
	if not self._bundled then return true, nil end
	local started, err = self._bundled:start_missing_probes {
		lifetime_scope = self._scope,
		reaper_scope = self._scope,
		report_scope = self._scope,
		artifact_store = self._artifact_store,
		done_tx = self._done_tx,
	}
	if not started then return nil, err or 'bundled_probe_start_failed' end
	assert_update_generation_model(self)
	return true, nil
end

local function start_bundled_applies(self)
	if not self._bundled then return true, nil end
	local started, err = self._bundled:start_ready_applies {
		lifetime_scope = self._scope,
		reaper_scope = self._scope,
		report_scope = self._scope,
		jobs = self._jobs,
		done_tx = self._done_tx,
	}
	if not started then return nil, err or 'bundled_apply_start_failed' end
	assert_update_generation_model(self)
	return true, nil
end

local function handle_bundled_probe_done(self, ev)
	local ok, err = self._bundled:handle_probe_done(ev)
	if ok ~= true then return ok, err end
	local aok, aerr = start_bundled_applies(self)
	if aok ~= true then error(aerr or 'bundled_apply_start_failed', 0) end
	assert_update_generation_model(self)
	return true, nil
end

local function handle_bundled_apply_done(self, ev)
	local ok, err = self._bundled:handle_apply_done(ev)
	if ok ~= true then return ok, err end
	assert_update_generation_model(self)
	return true, nil
end

local function reduce_event(self, ev)
	if ev.kind == 'manager_closed' then
		error('update manager endpoint closed', 0)
	end

	if ev.kind == 'service_route_closed' then
		error('update generation service route closed', 0)
	end

	if ev.kind == 'service_active_snapshot' then
		handle_service_active_snapshot(self, ev)
		return
	end

	if ev.kind == 'manager_request' then
		handle_manager_request(self, ev.request)
		return
	end

	if ev.kind == 'manager_request_done' then
		handle_manager_done(self, ev)
		return
	end

	if ev.kind == 'ingest_request' or ev.kind == 'ingest_closed' then
		self._ingest:handle_event(make_manager_context(self), ev)
		assert_update_generation_model(self)
		return
	end

	if ev.kind == 'ingest_request_done' or ev.kind == 'ingest_create_done' then
		self._ingest:handle_done(make_manager_context(self), ev)
		assert_update_generation_model(self)
		return
	end

	if ev.kind == 'bundled_probe_done' then
		handle_bundled_probe_done(self, ev)
		return
	end

	if ev.kind == 'bundled_apply_done' then
		handle_bundled_apply_done(self, ev)
		return
	end

	if ev.kind == 'completion_queue_closed' then
		error('update generation completion queue closed', 0)
	end

	error('update.generation: unknown event kind: ' .. tostring(ev.kind), 0)
end

local function coordinator_loop(self)
	assert_update_generation_model(self)

	while true do
		local ev = fibers.perform(generation_events.next_op(self))
		reduce_event(self, ev)
	end
end

function M.run(scope, params)
	params = params or {}
	local snapshot = M.initial_snapshot(params)
	local m = model_mod.new(snapshot, { label = 'update.generation' })

	scope:finally(function (_, status, primary)
		m:terminate(primary or status or 'generation_closed')
	end)

	local observer = observe_mod.new({
		service_id = params.service_id or 'update',
		components = (params.config and params.config.components) or {},
	})
	scope:finally(function (_, status, primary)
		observer:terminate(primary or status or 'generation_closed')
	end)

	local jobs = params.jobs
	if not jobs then
		error('update generation requires service-owned job runtime', 0)
	end

	local done_tx, done_rx = mailbox.new(params.done_queue_len or DEFAULT_DONE_QUEUE, {
		full = 'reject_newest',
	})
	scope:finally(function ()
		done_tx:close('generation_closed')
	end)

	local request_root, request_root_err = scope:child()
	if not request_root then
		error(request_root_err or 'update_generation_request_root_create_failed', 0)
	end

	local ingest_state = ingest_mod.new_state(scope, {
		queue_len = params.ingest_queue_len,
	})

	local bundled_state = bundled_mod.new({
		service_id = params.service_id or 'update',
		generation = params.generation or snapshot.generation,
		config = (params.config and params.config.bundled) or {},
	})

	local parent_events
	if params.events_tx ~= nil then
		parent_events = service_events.port(params.events_tx, {
			service_id  = params.service_id or 'update',
			source      = 'update_generation',
			source_id   = tostring(params.generation or snapshot.generation),
			generation  = params.generation or snapshot.generation,
		}, {
			label = 'update_generation_event_admission_failed',
		})
	end

	local self = setmetatable({
		_scope = scope,
		_request_root = request_root,
		_service_id = params.service_id or 'update',
		_generation = params.generation or snapshot.generation,
		_config = params.config or config_mod.default(),
		_model = m,
		_jobs = jobs,
		_observer = observer,
		_ingest = ingest_state,
		_bundled = bundled_state,
		_artifact_store = params.artifact_store,
		manager_rx = params.manager_rx,
		service_rx = params.service_rx,
		done_rx = done_rx,
		pending = {},
		_done_tx = done_tx,
		_done_rx = done_rx,
		_manager_work = {},
		_active_snapshot = copy(params.active_snapshot),
		_events = parent_events,
	}, Generation)

	local bok, berr = start_bundled_probes(self)
	if bok ~= true then error(berr or 'bundled_probe_start_failed', 0) end

	return coordinator_loop(self)
end

M.Generation = Generation

return M
