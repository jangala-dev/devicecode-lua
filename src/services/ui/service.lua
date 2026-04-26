-- services/ui/service.lua
--
-- UI service shell.
--
-- Responsibilities:
--   * own session store and aggregate UI state
--   * own the UI read model
--   * publish lifecycle through svc/ui/... and observability through obs/v1/ui/...
--   * host the HTTP/WebSocket transport
--
-- Design notes:
--   * local state changes are signalled via a scoped pulse
--   * model changes are consumed as first-class events
--   * authenticated user work is centralised through run_user_call(...)

local fibers    = require 'fibers'
local pulse     = require 'fibers.pulse'
local safe      = require 'coxpcall'
local scope     = require 'fibers.scope'
local op        = require 'fibers.op'

local base        = require 'devicecode.service_base'
local auth_mod    = require 'services.ui.auth'
local sessions    = require 'services.ui.sessions'
local model_mod   = require 'services.ui.model'
local app_mod     = require 'services.ui.app'
local uploads_mod = require 'services.ui.uploads'
local http_mod    = require 'services.ui.transport.http'
local errors      = require 'services.ui.errors'

local M = {}

local function now()
	return fibers.now()
end

local function start_child(fn)
	local parent = scope.current()
	local child, err = parent:child()
	if not child then
		error(err or 'failed to create child scope', 0)
	end

	local ok, serr = child:spawn(function(s)
		fn(s)
	end)
	if not ok then
		error(serr or 'failed to start child scope', 0)
	end

	return child
end

local function default_announce(svc)
	return {
		role = 'ui',
		auth = 'local-session',
		caps = {
			login = true,
			logout = true,
			session = true,
			model_exact = true,
			model_snapshot = true,
			config_get = true,
			config_set = true,
			service_status = true,
			services_snapshot = true,
			fabric_status = true,
			fabric_link_status = true,
			watch = true,
			update_job_create = true,
			update_job_get = true,
			update_job_list = true,
			update_job_do = true,
			update_job_upload = true,
		},
	}
end

function M.start(conn, opts)
	opts = opts or {}
	if type(opts.connect) ~= 'function' then
		error('ui: opts.connect(principal, origin_extra) is required', 2)
	end

	local svc = base.new(conn, { name = opts.name or 'ui', env = opts.env })
	local verify_login = opts.verify_login or auth_mod.bootstrap_verify_login
	local session_ttl_s = (type(opts.session_ttl_s) == 'number' and opts.session_ttl_s > 0) and opts.session_ttl_s or 3600
	local session_prune_s = (type(opts.session_prune_s) == 'number' and opts.session_prune_s > 0) and opts.session_prune_s or 60
	local model_ready_timeout_s = (type(opts.model_ready_timeout_s) == 'number' and opts.model_ready_timeout_s > 0) and opts.model_ready_timeout_s or 2.0

	local shell_pulse = pulse.scoped({ close_reason = 'ui shell closed' })
	local session_store = sessions.new_store({ now = now })

	local aggregate = {
		sessions = 0,
		clients = 0,
		model_ready = false,
		model_seq = 0,
		status = 'starting',
	}

	local client_count = 0
	local model

	local function publish_main_state(extra)
		local status = {
			sessions = aggregate.sessions,
			clients = aggregate.clients,
			model_ready = aggregate.model_ready,
			model_seq = aggregate.model_seq,
		}

		local payload = {
			status = aggregate.status,
			sessions = aggregate.sessions,
			clients = aggregate.clients,
			model_ready = aggregate.model_ready,
			model_seq = aggregate.model_seq,
			t = now(),
		}
		for k, v in pairs(extra or {}) do
			payload[k] = v
			status[k] = v
		end

		if aggregate.status == 'starting' then
			svc:starting(status)
		elseif aggregate.status == 'running' then
			svc:set_ready(true, status)
		elseif aggregate.status == 'degraded' then
			svc:degraded(status)
		elseif aggregate.status == 'failed' then
			svc:failed(status.reason or 'failed', status)
		else
			svc:status(aggregate.status, status)
		end

	end

	local function recompute_aggregate()
		local changed = false
		local sessions_n = session_store:count()
		local model_ready = model and model:is_ready() or false
		local model_seq = model and model:seq() or 0
		local clients_n = client_count

		if aggregate.sessions ~= sessions_n then
			aggregate.sessions = sessions_n
			changed = true
		end
		if aggregate.clients ~= clients_n then
			aggregate.clients = clients_n
			changed = true
		end
		if aggregate.model_ready ~= model_ready then
			aggregate.model_ready = model_ready
			changed = true
		end
		if aggregate.model_seq ~= model_seq then
			aggregate.model_seq = model_seq
			changed = true
		end

		return changed
	end

	local function next_shell_event_op(last_local_ver, last_model_seq, prune_s)
		return op.choice(
			shell_pulse:changed_op(last_local_ver):wrap(function(ver, reason)
				if ver == nil then
					return { tag = 'shell_closed', reason = tostring(reason or 'closed') }
				end
				return { tag = 'local_changed', ver = ver }
			end),

			model:next_change_op(last_model_seq, prune_s):wrap(function(seq, err)
				if seq == nil then
					if err == 'timeout' then
						return { tag = 'prune_tick' }
					end
					return { tag = 'model_closed', reason = tostring(err or 'closed') }
				end
				return { tag = 'model_changed', seq = seq }
			end)
		)
	end

	local function signal_shell_change()
		shell_pulse:signal()
	end

	local function notify_sessions_changed()
		signal_shell_change()
	end

	local function notify_client_delta(delta)
		client_count = math.max(0, client_count + (delta or 0))
		signal_shell_change()
	end

	local function audit(kind, payload)
		conn:publish({ 'obs', 'v1', 'ui', 'event', kind }, payload or {})
	end

	local function require_session(session_id)
		if type(session_id) ~= 'string' or session_id == '' then
			return nil, errors.unauthorised('missing session')
		end

		local rec = session_store:get(session_id)
		if not rec then
			return nil, errors.unauthorised('invalid or expired session')
		end

		session_store:touch(session_id, session_ttl_s)
		return rec, nil
	end

	-- Boundary for user-supplied connection acquisition.
	local function open_user_conn(principal, origin_extra)
		local ok, a, b = safe.pcall(opts.connect, principal, origin_extra)
		if not ok then
			return nil, errors.unavailable(tostring(a))
		end
		if not a then
			return nil, errors.unavailable(tostring(b or 'connect failed'))
		end
		return a, nil
	end

	-- Open a temporary user connection for one bounded unit of work.
	local function with_user_conn(principal, origin_extra, fn)
		local st, _report, a, b, c = scope.run(function(s)
			local user_conn, err = open_user_conn(principal, origin_extra)
			if not user_conn then
				error(err, 0)
			end

			s:finally(function()
				user_conn:disconnect()
			end)

			return fn(user_conn)
		end)

		if st ~= 'ok' then
			return nil, errors.from(a, 502)
		end
		return a, b, c
	end

	-- Run one authenticated user operation either against an existing connection
	-- or a temporary one, while mapping thrown failures into UI errors.
	local function run_user_call(rec, origin_extra, existing_conn, fn)
		if existing_conn then
			local st, _report, a, b, c = scope.run(function()
				return fn(existing_conn)
			end)
			if st ~= 'ok' then
				return nil, errors.from(a, 502)
			end
			return a, b, c
		end

		return with_user_conn(rec.principal, origin_extra, fn)
	end

	model = model_mod.start(conn, {
		queue_len = opts.model_queue_len or 512,
		sources = opts.model_sources,
	})

	local ctx = {
		svc = svc,
		now = now,
		sessions = session_store,
		session_ttl_s = session_ttl_s,
		verify_login = verify_login,
		model = model,
		require_session = require_session,
		open_user_conn = open_user_conn,
		with_user_conn = with_user_conn,
		run_user_call = run_user_call,
		note_session_count = notify_sessions_changed,
		audit = audit,
	}
	ctx.uploads = uploads_mod.new({
		require_session = require_session,
		with_user_conn = with_user_conn,
	})

	local app = app_mod.new(ctx)
	local run_http = opts.run_http or http_mod.run

	fibers.current_scope():finally(function()
		if model then
			model:close('ui service stopping')
		end
	end)

	aggregate.status = 'starting'
	svc:announce(default_announce(svc))
	publish_main_state()

	local ok_ready, ready_err = model:await_ready(model_ready_timeout_s)
	if not ok_ready then
		aggregate.status = 'failed'
		publish_main_state({ reason = errors.message(ready_err) })
		error('ui: failed to bootstrap retained model: ' .. tostring(errors.message(ready_err)), 0)
	end

	recompute_aggregate()

	local ok_http, err_http = fibers.spawn(function()
		run_http(svc, app, {
			host = opts.host,
			port = opts.port,
			www_root = opts.www_root,
			spawn_ws_client = function(fn)
				start_child(function()
					fn()
				end)
			end,
			ws_opts = {
				session_id_from_headers = http_mod.session_id_from_headers,
				open_user_conn = open_user_conn,
				require_session = require_session,
				on_opened = function() notify_client_delta(1) end,
				on_closed = function() notify_client_delta(-1) end,
			},
		})
	end)
	if ok_http ~= true then
		aggregate.status = 'failed'
		publish_main_state({ reason = tostring(err_http or 'failed to start http transport') })
		error(err_http or 'failed to start http transport', 0)
	end

	aggregate.status = 'running'
	recompute_aggregate()
	svc:running({
		sessions = aggregate.sessions,
		clients = aggregate.clients,
		model_ready = aggregate.model_ready,
		model_seq = aggregate.model_seq,
	})
	publish_main_state()

	local last_local_ver = shell_pulse:version()
	local last_model_seq = model:seq()

	while true do
		local ev = fibers.perform(next_shell_event_op(last_local_ver, last_model_seq, session_prune_s))

		if ev.tag == 'shell_closed' then
			error('ui shell pulse closed: ' .. tostring(ev.reason or 'closed'), 0)

		elseif ev.tag == 'prune_tick' then
			local removed = session_store:prune()
			if removed > 0 then
				recompute_aggregate()
				publish_main_state()
			end

		elseif ev.tag == 'local_changed' then
			last_local_ver = ev.ver or shell_pulse:version()
			if recompute_aggregate() then
				publish_main_state()
			end

		elseif ev.tag == 'model_changed' then
			last_model_seq = ev.seq or model:seq()
			if recompute_aggregate() then
				publish_main_state()
			end

		elseif ev.tag == 'model_closed' then
			aggregate.status = 'failed'
			publish_main_state({ reason = tostring(ev.reason or 'closed') })
			error('ui model closed: ' .. tostring(ev.reason or 'closed'), 0)
		end
	end
end

return M
