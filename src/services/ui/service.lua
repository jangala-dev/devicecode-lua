local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local safe    = require 'coxpcall'
local scope   = require 'fibers.scope'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'

local base      = require 'devicecode.service_base'
local auth_mod  = require 'services.ui.auth'
local sessions  = require 'services.ui.sessions'
local model_mod = require 'services.ui.model'
local app_mod   = require 'services.ui.app'
local http_mod  = require 'services.ui.transport.http'
local errors    = require 'services.ui.errors'

local M = {}

local function now()
	return fibers.now()
end

local function send_required(tx, item, what)
	local ok, reason = tx:send(item)
	if ok == true then return true end
	error((what or 'ui ctl queue') .. ': ' .. tostring(reason or 'closed'), 0)
end

local function start_child(fn)
	local parent = scope.current()
	local child, err = parent:child()
	if not child then error(err or 'failed to create child scope', 0) end
	local ok, serr = child:spawn(function(s)
		fn(s)
	end)
	if not ok then error(serr or 'failed to start child scope', 0) end
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
			capability_snapshot = true,
			call = true,
			watch = true,
		},
	}
end

local function next_shell_event_op(ctl_rx, prune_s)
	return op.choice(
		ctl_rx:recv_op():wrap(function(ev)
			if ev == nil then
				return { tag = 'ctl_closed', reason = tostring(ctl_rx:why() or 'closed') }
			end
			return ev
		end),
		sleep.sleep_op(prune_s):wrap(function()
			return { tag = 'prune_tick' }
		end)
	)
end

function M.start(conn, opts)
	opts = opts or {}
	if type(opts.connect) ~= 'function' then error('ui: opts.connect(principal, origin_extra) is required', 2) end
	local svc = base.new(conn, { name = opts.name or 'ui', env = opts.env })
	local verify_login = opts.verify_login or auth_mod.bootstrap_verify_login
	local session_ttl_s = (type(opts.session_ttl_s) == 'number' and opts.session_ttl_s > 0) and opts.session_ttl_s or 3600
	local session_prune_s = (type(opts.session_prune_s) == 'number' and opts.session_prune_s > 0) and opts.session_prune_s or 60
	local model_ready_timeout_s = (type(opts.model_ready_timeout_s) == 'number' and opts.model_ready_timeout_s > 0) and opts.model_ready_timeout_s or 2.0

	local ctl_tx, ctl_rx = mailbox.new(128, { full = 'reject_newest' })
	local session_store = sessions.new_store({ now = now })
	local aggregate = {
		sessions = 0,
		clients = 0,
		model_ready = false,
		model_seq = 0,
		status = 'starting',
	}

	local function retain_state(extra)
		local payload = {
			status = aggregate.status,
			sessions = aggregate.sessions,
			clients = aggregate.clients,
			model_ready = aggregate.model_ready,
			model_seq = aggregate.model_seq,
			t = now(),
		}
		for k, v in pairs(extra or {}) do payload[k] = v end
		conn:retain({ 'state', 'ui', 'main' }, payload)
	end

	local function note_session_count()
		send_required(ctl_tx, { tag = 'session_count', value = session_store:count() }, 'ui ctl')
	end

	local function note_client_delta(delta)
		send_required(ctl_tx, { tag = 'client_delta', value = delta or 0 }, 'ui ctl')
	end

	local function audit(kind, payload)
		conn:publish({ 'obs', 'audit', 'ui', kind }, payload or {})
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

	local function open_user_conn(principal, origin_extra)
		local ok, a, b = safe.pcall(opts.connect, principal, origin_extra)
		if not ok then return nil, errors.unavailable(tostring(a)) end
		if not a then return nil, errors.unavailable(tostring(b or 'connect failed')) end
		return a, nil
	end

	local function with_user_conn(principal, origin_extra, fn)
		local user_conn, err = open_user_conn(principal, origin_extra)
		if not user_conn then return nil, err end
		local ok, a, b, c = safe.pcall(fn, user_conn)
		pcall(function() user_conn:disconnect() end)
		if not ok then return nil, errors.from(a, 502) end
		return a, b, c
	end

	local model = model_mod.start(conn, {
		report_tx = ctl_tx,
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
		note_session_count = note_session_count,
		audit = audit,
	}

	local app = app_mod.new(ctx)
	local run_http = opts.run_http or http_mod.run

	svc:status('starting')
	conn:retain({ 'svc', svc.name, 'announce' }, default_announce(svc))
	retain_state()
	local ok_ready, ready_err = model:await_ready(model_ready_timeout_s)
	if not ok_ready then
		aggregate.status = 'failed'
		retain_state({ reason = errors.message(ready_err) })
		error('ui: failed to bootstrap retained model: ' .. tostring(errors.message(ready_err)), 0)
	end

	aggregate.status = 'running'
	aggregate.model_ready = true
	aggregate.model_seq = model:seq()
	svc:status('running')
	retain_state()

	fibers.spawn(function()
		run_http(svc, app, {
			host = opts.host,
			port = opts.port,
			www_root = opts.www_root,
			spawn_ws_client = function(fn)
				start_child(function() fn() end)
			end,
			ws_opts = {
				session_id_from_headers = http_mod.session_id_from_headers,
				open_user_conn = open_user_conn,
				require_session = require_session,
				on_opened = function() note_client_delta(1) end,
				on_closed = function() note_client_delta(-1) end,
			},
		})
	end)

	while true do
		local ev = fibers.perform(next_shell_event_op(ctl_rx, session_prune_s))
		if ev.tag == 'ctl_closed' then
			error('ui ctl closed: ' .. tostring(ev.reason or 'closed'), 0)
		elseif ev.tag == 'prune_tick' then
			local removed = session_store:prune()
			if removed > 0 then
				aggregate.sessions = session_store:count()
				retain_state()
			end
		elseif ev.tag == 'model_ready' then
			aggregate.model_ready = true
			aggregate.model_seq = ev.seq or aggregate.model_seq
			retain_state()
		elseif ev.tag == 'model_seq' then
			aggregate.model_seq = ev.seq or aggregate.model_seq
			retain_state()
		elseif ev.tag == 'model_closed' then
			aggregate.status = 'failed'
			retain_state({ reason = tostring(ev.reason or 'closed') })
			error('ui model closed: ' .. tostring(ev.reason or 'closed'), 0)
		elseif ev.tag == 'session_count' then
			aggregate.sessions = ev.value or session_store:count()
			retain_state()
		elseif ev.tag == 'client_delta' then
			aggregate.clients = math.max(0, aggregate.clients + (ev.value or 0))
			retain_state()
		end
	end
end

return M
