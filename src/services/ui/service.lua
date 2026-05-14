-- services/ui/service.lua
--
-- Top-level UI service coordinator. It owns service-level status and starts
-- long-lived scoped components. It does not own HTTP request work,
-- upstream calls, or upload streams.

local fibers       = require 'fibers'
local mailbox      = require 'fibers.mailbox'
local service_base = require 'devicecode.service_base'
local scoped_work  = require 'devicecode.support.scoped_work'
local sleep        = require 'fibers.sleep'
local queue        = require 'devicecode.support.queue'
local read_model   = require 'services.ui.read_model'
local queries      = require 'services.ui.queries'
local sessions_mod = require 'services.ui.sessions'
local auth_mod     = require 'services.ui.auth'
local topics       = require 'services.ui.topics'
local supervision  = require 'services.ui.supervision'
local config_watch = require 'devicecode.support.config_watch'
local config_mod   = require 'services.ui.config'
local service_events = require 'devicecode.support.service_events'
local tablex = require 'shared.table'

local M = {}

local shallow_copy = tablex.shallow_copy

local function component_summary(components)
	local out = {}
	for name, c in pairs(components or {}) do
		out[name] = {
			status = c.status,
			primary = c.primary,
			reason = c.reason,
		}
	end
	return out
end

local function build_summary(state)
	local model_snapshot = state.model and state.model:snapshot() or nil
	return queries.summary(model_snapshot,
		state.sessions and state.sessions:count() or 0,
		{
			active_requests = state.active_requests,
			rejected_requests = state.rejected_requests or 0,
			last_rejection_reason = state.last_rejection_reason,
			read_model_status = state.read_model_status,
			listener_status = state.listener_status,
			config_status = state.config_status,
			config_generation = state.config_generation,
			service_status = state.service_status,
			components = component_summary(state.components),
			last_error = state.last_error,
		}
	)
end

local function publish_summary(state)
	-- UI summaries are presentation projections. They are intentionally not
	-- retained back to the bus because the read model consumes retained state/#.
	-- Publishing derived UI state there creates a self-ingesting projection loop.
	return build_summary(state)
end
local function record_cleanup_error(state, kind, err)
	local rec = {
		kind = kind or 'cleanup_error',
		err = tostring(err or 'cleanup failed'),
	}
	state.cleanup_errors = state.cleanup_errors or {}
	state.cleanup_errors[#state.cleanup_errors + 1] = rec
	state.last_cleanup_error = rec

	return rec
end

local function component_identity(component, generation)
	return {
		kind = 'ui_component_done',
		component = component,
		generation = generation,
	}
end

local function record_component_started(state, component, generation)
	state.components = state.components or {}
	local c = state.components[component] or {}
	if generation ~= nil and c.generation ~= nil and c.generation ~= generation then return false, 'stale_component_start' end
	c.status = 'running'
	if generation ~= nil then c.generation = generation end
	c.reason = nil
	c.primary = nil
	c.outcome = nil
	state.components[component] = c
	if component == 'read_model' then
		state.read_model_status = 'running'
	elseif component == 'http_listener' then
		state.listener_status = 'running'
	end
end

local function record_component_done(state, ev)
	state.components = state.components or {}
	local name = ev.component
	if type(name) ~= 'string' or name == '' then
		return false, 'missing_component'
	end
	local c = state.components[name] or {}
	if ev.generation ~= nil and c.generation ~= nil and ev.generation ~= c.generation then
		return false, 'stale_component_completion'
	end
	if c.status == 'ok' or c.status == 'failed' or c.status == 'cancelled' then
		return false, 'stale_component_completion'
	end
	c.status = ev.status
	c.outcome = ev
	if ev.status == 'ok' then
		c.result = ev.result
		c.reason = type(ev.result) == 'table' and (ev.result.reason or ev.result.status) or nil
	else
		c.primary = ev.primary
		c.reason = ev.primary
	end
	state.components[name] = c

	if name == 'read_model' then
		state.read_model_status = ev.status
	elseif name == 'http_listener' then
		state.listener_status = ev.status
	end
	return true, nil
end

local function apply_service_policy(state, ev)
	local decision = supervision.classify_service_component_done(state, ev)
	local action = decision.action or 'continue'
	if action == 'continue' then
		return { publish = true }
	elseif action == 'degrade_service' then
		state.service_status = 'degraded'
		state.last_error = decision.reason or ev.primary
		return { publish = true }
	elseif action == 'fail_service' then
		state.service_status = 'failed'
		state.last_error = decision.reason or ev.primary or 'ui component failed'
		return { publish = true, fail = state.last_error }
	elseif action == 'cancel_service' then
		state.service_status = 'stopping'
		state.last_error = decision.reason or ev.primary or 'ui component cancelled'
		if state.scope and state.scope.cancel then state.scope:cancel(state.last_error) end
		return { publish = true }
	end
	error('ui.service: unknown supervision action: ' .. tostring(action), 0)
end

local function start_component(state, component, run, generation)
	state.components[component] = { status = 'starting', generation = generation }
	local handle, err = scoped_work.start({
		lifetime_scope = state.scope,
		reaper_scope = state.scope,
		report_scope = state.scope,
		identity = component_identity(component, generation),
		run = function (scope)
			return run(scope)
		end,
		report = service_events.reporter(
			service_events.port(state.done_tx, {
				service_id = state.service_id or 'ui',
				source = 'ui_component',
				source_id = component,
				component = component,
				generation = generation,
			}, { label = 'ui_component_done_report_failed' }),
			'ui_component_done_report_failed'
		),
	})
	if not handle then error(err or ('failed to start ' .. component), 0) end
	return handle
end



local function run_session_pruner(_, sessions, interval)
	while true do
		fibers.perform(sleep.sleep_op(interval))
		sessions:prune()
	end
end

local function listener_config_key(cfg)
	if not cfg or not cfg.enabled or not cfg.http or cfg.http.enabled == false then return 'disabled' end
	local h = cfg.http
	return table.concat({
		tostring(h.cap_id or 'main'),
		tostring(h.host or ''),
		tostring(h.port or ''),
		tostring(h.path or ''),
		tostring(h.tls or false),
		tostring(h.max_accept_queue or ''),
	}, '|')
end

local function build_listener_opts(state, cfg, listener_generation, listener_id)
	local params = state.params or {}
	local h = cfg.http or {}
	local s = cfg.static or {}
	local sse_cfg = cfg.sse or {}
	local uploads = cfg.uploads or {}

	local listen = {
		host = h.host,
		port = h.port,
		path = h.path,
		tls = h.tls,
		max_accept_queue = h.max_accept_queue,
	}

	local update_opts = shallow_copy(params.update or {})
	update_opts.max_bytes = uploads.max_bytes
	update_opts.enabled = uploads.enabled
	update_opts.connect = update_opts.connect or params.connect
	update_opts.bus = update_opts.bus or params.bus

	return {
		listener = params.listener,
		conn = state.conn,
		listen = listen,
		cap_id = h.cap_id or 'main',
		call_opts = params.http_call_opts,
		bus = params.bus,
		model = state.model,
		watch_owner = state.watch_owner,
		sessions = state.sessions,
		auth = state.auth,
		connect = params.connect,
		events_port = service_events.port(state.done_tx, {
			service_id = state.service_id or 'ui',
			source = 'ui_http_listener',
			source_id = listener_id or ('http_listener:' .. tostring(listener_generation or state.listener_generation or 0)),
			listener_id = listener_id or ('http_listener:' .. tostring(listener_generation or state.listener_generation or 0)),
			generation = listener_generation or state.listener_generation,
		}, { label = 'ui_http_listener_event_report_failed' }),
		root = s.root,
		chunk_size = s.chunk_size,
		encode_json = params.encode_json,
		max_active_requests = h.max_active_requests,
		overload_reason = params.overload_reason,
		reject_overloaded_request_now = params.reject_overloaded_request_now,
		sse = {
			enabled = sse_cfg.enabled,
			queue_len = sse_cfg.queue_len,
			max_replay = sse_cfg.max_replay,
			replay = sse_cfg.replay,
			pattern = sse_cfg.pattern,
		},
		update = update_opts,
	}
end

local function cancel_listener(state, reason)
	if state.listener_handle and type(state.listener_handle.cancel) == 'function' then
		state.listener_handle:cancel(reason or 'ui_config_changed')
	end
	state.listener_handle = nil
	state.listener_config_key = nil
	state.listener_generation = (state.listener_generation or 0) + 1
	state.components = state.components or {}
	state.components.http_listener = { status = 'disabled', generation = state.listener_generation }
	state.listener_status = 'disabled'
	state.active_requests = 0
	return true
end

local function start_configured_listener(state, cfg, generation)
	local key = listener_config_key(cfg)
	if key == 'disabled' then
		cancel_listener(state, 'ui_http_disabled')
		return true
	end
	if state.listener_handle and state.listener_config_key == key then return true end
	cancel_listener(state, 'ui_http_reconfigured')
	state.listener_generation = generation or ((state.listener_generation or 0) + 1)
	state.listener_config_key = key
	state.listener_status = 'starting'
	local listener_generation = state.listener_generation
	local listener_id = 'http_listener:' .. tostring(listener_generation)
	state.listener_handle = start_component(state, 'http_listener', function (component_scope)
		queue.assert_admit_required(state.done_tx, {
			kind = 'component_started',
			component = 'http_listener',
			generation = listener_generation,
		}, 'ui_http_listener_start_report_failed')
		local listener_mod = require 'services.ui.http.listener'
		listener_mod.run(component_scope, build_listener_opts(state, cfg, listener_generation, listener_id))
		return { status = 'stopped' }
	end, listener_generation)
	return true
end

local function cancel_session_pruner(state, reason)
	if state.session_pruner_handle and type(state.session_pruner_handle.cancel) == 'function' then
		state.session_pruner_handle:cancel(reason or 'ui_session_pruner_reconfigured')
	end
	state.session_pruner_handle = nil
	state.session_pruner_key = nil
	state.session_pruner_generation = (state.session_pruner_generation or 0) + 1
	state.components = state.components or {}
	state.components.session_pruner = { status = 'disabled', generation = state.session_pruner_generation }
	return true
end

local function start_configured_session_pruner(state, cfg, generation)
	local sessions_cfg = cfg and cfg.sessions or {}
	local interval = sessions_cfg.prune_interval
	if interval == false or interval == nil then
		cancel_session_pruner(state, 'ui_session_pruner_disabled')
		return true
	end
	local key = tostring(interval)
	if state.session_pruner_handle and state.session_pruner_key == key then return true end
	cancel_session_pruner(state, 'ui_session_pruner_reconfigured')
	state.session_pruner_generation = generation or ((state.session_pruner_generation or 0) + 1)
	state.session_pruner_key = key
	local pruner_generation = state.session_pruner_generation
	state.session_pruner_handle = start_component(state, 'session_pruner', function (component_scope)
		queue.assert_admit_required(state.done_tx, {
			kind = 'component_started',
			component = 'session_pruner',
			generation = pruner_generation,
		}, 'ui_session_pruner_start_report_failed')
		return run_session_pruner(component_scope, state.sessions, interval)
	end, pruner_generation)
	return true
end

local function apply_config(state, raw, generation)
	local cfg, err = config_mod.normalise(raw or {})
	if not cfg then
		state.config_status = 'invalid'
		state.last_error = tostring(err or 'invalid_config')
		state.service_status = 'degraded'
		return { publish = true }
	end

	state.config = cfg
	state.config_generation = generation or ((state.config_generation or 0) + 1)
	state.config_status = 'ok'
	if state.service_status == 'starting' or state.service_status == 'degraded' then
		state.service_status = 'running'
	end

	if cfg.enabled == false then
		cancel_listener(state, 'ui_disabled')
		cancel_session_pruner(state, 'ui_disabled')
		state.service_status = 'disabled'
		return { publish = true }
	end

	start_configured_listener(state, cfg, state.config_generation)
	start_configured_session_pruner(state, cfg, state.config_generation)
	return { publish = true }
end

local function cfg_event_from_watch(ev)
	if ev == nil then return nil end
	if ev.kind == 'config_closed' then
		return { kind = 'config_closed', err = ev.err }
	end
	return {
		kind = 'config_changed',
		generation = ev.generation,
		rev = ev.rev,
		raw = ev.raw,
	}
end


local function is_session_event(ev)
	local k = ev and ev.kind
	return k == 'session_created'
		or k == 'session_touched'
		or k == 'session_deleted'
		or k == 'session_pruned'
		or k == 'session_count_changed'
end

local function reduce_event(state, ev)
	if ev.kind == 'component_started' then
		record_component_started(state, ev.component, ev.generation)
		return { publish = true }
	elseif ev.kind == 'config_changed' then
		return apply_config(state, ev.raw, ev.generation)
	elseif ev.kind == 'config_closed' then
		state.config_status = 'closed'
		state.last_error = ev.err
		return { publish = true }
	elseif ev.kind == 'ui_component_done' then
		local accepted = record_component_done(state, ev)
		if not accepted then return {} end
		return apply_service_policy(state, ev)
	elseif ev.kind == 'read_model_changed' then
		state.model_seen = ev.version or state.model_seen
		return { publish = true }
	elseif ev.kind == 'session_changed' then
		state.sessions_seen = ev.version or state.sessions_seen
		state.last_session_event = ev.last_event or ev
		return { publish = true }
	elseif is_session_event(ev) then
		state.last_session_event = ev
		return { publish = true }
	elseif ev.kind == 'http_request_done' then
		if ev.generation ~= nil and state.listener_generation ~= nil and ev.generation ~= state.listener_generation then return {} end
		if type(ev.active_requests) == 'number' then
			state.active_requests = ev.active_requests
		else
			state.active_requests = math.max(0, (state.active_requests or 0) - 1)
		end
		return { publish = true }
	elseif ev.kind == 'http_request_started' then
		if ev.generation ~= nil and state.listener_generation ~= nil and ev.generation ~= state.listener_generation then return {} end
		if type(ev.active_requests) == 'number' then
			state.active_requests = ev.active_requests
		else
			state.active_requests = (state.active_requests or 0) + 1
		end
		return { publish = true }
	elseif ev.kind == 'http_request_rejected' then
		if ev.generation ~= nil and state.listener_generation ~= nil and ev.generation ~= state.listener_generation then return {} end
		state.rejected_requests = (state.rejected_requests or 0) + 1
		state.last_rejection_reason = ev.reason
		return { publish = true }
	elseif ev.kind == 'read_model_closed' then
		state.read_model_status = 'closed'
		return { publish = true }
	end
	return {}
end

local function next_event_op(state)
	local arms = {
		done = state.done_rx:recv_op(),
		cfg = state.cfg_watch:recv_op():wrap(cfg_event_from_watch),
		model = state.model:changed_op(state.model_seen):wrap(function (version, snapshot, err)
			if version == nil then
				return { kind = 'read_model_closed', err = err }
			end
			return { kind = 'read_model_changed', version = version, snapshot = snapshot }
		end),
	}

	if state.sessions and type(state.sessions.changed_op) == 'function' then
		arms.sessions = state.sessions:changed_op(state.sessions_seen or 0):wrap(function (version, snapshot, err)
			if version == nil then
				return { kind = 'session_model_closed', err = err }
			end
			return {
				kind = 'session_changed',
				version = version,
				snapshot = snapshot,
				last_event = snapshot and snapshot.last_event or nil,
			}
		end)
	end

	return fibers.named_choice(arms):wrap(function (_, ev)
		return ev
	end)
end

function M.run(scope, params)
	params = params or {}
	local conn = assert(params.conn, 'ui.service.run: conn required')
	local done_tx, done_rx = mailbox.new(params.done_queue_len or 128, { full = 'reject_newest' })
	local sessions = params.sessions or sessions_mod.new(params.session_opts)
	local auth = params.auth or auth_mod.new(params.auth_opts or {})
	local model = params.model or read_model.new(params.read_model_opts)
	local watch_owner = params.watch_owner or params.watches or read_model.new_watches(model, params.watch_opts or params.read_model_opts)
	local read_model_owns_model = false

	local cfg_watch, cfg_err = config_watch.open(conn, 'ui', {
		topic = params.config_topic or { 'cfg', 'ui' },
		queue_len = params.config_queue_len or 4,
		full = 'reject_newest',
	})
	if not cfg_watch then error(cfg_err or 'ui config subscribe failed', 2) end

	local state = {
		scope = scope,
		params = params,
		service_id = params.service_id or 'ui',
		conn = conn,
		cfg_watch = cfg_watch,
		done_tx = done_tx,
		done_rx = done_rx,
		sessions = sessions,
		auth = auth,
		model = model,
		watch_owner = watch_owner,
		model_seen = model:version(),
		sessions_seen = (type(sessions.version) == 'function') and sessions:version() or 0,
		service_status = 'starting',
		read_model_status = 'starting',
		listener_status = 'disabled',
		config_status = 'waiting',
		config_generation = 0,
		active_requests = 0,
		rejected_requests = 0,
		components = {},
		last_error = nil,
	}

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'ui_service_closed'
		cancel_listener(state, reason)
		cancel_session_pruner(state, reason)
		cfg_watch:close()
		done_tx:close(reason)
		if not read_model_owns_model then
			watch_owner:terminate(reason)
			model:terminate(reason)
		end
	end)

	local read_handle = start_component(state, 'read_model', function (component_scope)
		local read_model_opts = shallow_copy(params.read_model_opts or {})
		read_model_opts.model = model
		read_model_opts.watch_owner = watch_owner
		read_model_owns_model = true
		read_model.start(component_scope, conn, read_model_opts)
		queue.assert_admit_required(done_tx, { kind = 'component_started', component = 'read_model' }, 'ui_read_model_start_report_failed')
		fibers.perform(fibers.never())
	end)
	state.read_model_handle = read_handle

	state.service_status = 'running'

	publish_summary(state)

	while true do
		local ev = fibers.perform(next_event_op(state))
		if ev == nil then error('ui service event source closed', 0) end
		local decision = reduce_event(state, ev)
		if decision.publish then publish_summary(state) end
		if decision.fail then error(decision.fail, 0) end
	end
end

function M.start(conn, opts)
	opts = opts or {}
	if conn == nil then error('ui.start: conn required', 2) end
	local scope = fibers.current_scope()
	if not scope then error('ui.start must be called inside a fiber', 2) end

	local svc = service_base.new(conn, {
		name = opts.name or 'ui',
		env = opts.env,
		meta = opts.meta,
		announce = opts.announce,
	})
	svc:starting({ ready = false })

	local params = shallow_copy(opts)
	params.conn = conn
	svc:running({ ready = true })
	return M.run(scope, params)
end

M._test = {
	reduce_event = reduce_event,
	record_component_done = record_component_done,
	apply_service_policy = apply_service_policy,
	publish_summary = publish_summary,
	record_cleanup_error = record_cleanup_error,
	apply_config = apply_config,
}


return M
