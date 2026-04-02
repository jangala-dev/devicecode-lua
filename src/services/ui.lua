-- services/ui.lua
--
-- UI service skeleton for the current runtime.
--
-- Scope of this first step:
--   * keep HTTP/WebSocket transport outside this file
--   * own login/session logic here
--   * use opts.connect(principal) to act on behalf of logged-in users
--   * start with admin-only access
--
-- Expected next layer:
--   * a lua-http transport module calls the API functions returned here
--   * later, a dedicated auth service should replace the temporary password check

local fibers = require 'fibers'
local uuid   = require 'uuid'

local safe = require 'coxpcall'

local base   = require 'devicecode.service_base'
local authz  = require 'devicecode.authz'

local M = {}

local function now()
	return fibers.now()
end

local function getenv_nonempty(name)
	local v = os.getenv(name)
	if v == nil or v == '' then
		return nil
	end
	return v
end

local function copy_plain(t)
	if type(t) ~= 'table' then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		if type(v) == 'table' then
			out[k] = copy_plain(v)
		else
			out[k] = v
		end
	end
	return out
end

local function temporary_verify_login(username, password)
	-- Temporary bootstrap mechanism:
	--   * only "admin" is recognised
	--   * password comes from DEVICECODE_UI_ADMIN_PASSWORD
	--
	-- Replace this with a proper auth service and slow password hashes.
	local expected = getenv_nonempty('DEVICECODE_UI_ADMIN_PASSWORD')
	if not expected then
		return nil, 'ui admin password is not configured'
	end

	if username ~= 'admin' then
		return nil, 'invalid credentials'
	end

	if type(password) ~= 'string' or password ~= expected then
		return nil, 'invalid credentials'
	end

	return authz.user_principal('admin', { roles = { 'admin' } }), nil
end

local function make_session_store()
	local by_id = {}

	local store = {}

	function store:create(principal, ttl_s)
		local sid = tostring(uuid.new())
		local rec = {
			id         = sid,
			principal  = principal,
			created_at = now(),
			expires_at = now() + (ttl_s or 3600),
		}
		by_id[sid] = rec
		return rec
	end

	function store:get(session_id)
		local rec = by_id[session_id]
		if not rec then
			return nil
		end
		if rec.expires_at <= now() then
			by_id[session_id] = nil
			return nil
		end
		return rec
	end

	function store:touch(session_id, ttl_s)
		local rec = self:get(session_id)
		if not rec then
			return nil
		end
		rec.expires_at = now() + (ttl_s or 3600)
		return rec
	end

	function store:delete(session_id)
		by_id[session_id] = nil
		return true
	end

	function store:prune()
		local t = now()
		for sid, rec in pairs(by_id) do
			if rec.expires_at <= t then
				by_id[sid] = nil
			end
		end
	end

	function store:count()
		local n = 0
		for _ in pairs(by_id) do n = n + 1 end
		return n
	end

	return store
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, {
		name = opts.name or 'ui',
		env  = opts.env,
	})

	if type(opts.connect) ~= 'function' then
		error('ui: opts.connect(principal) is required', 2)
	end

	local verify_login = opts.verify_login or temporary_verify_login
	local session_ttl_s = (type(opts.session_ttl_s) == 'number' and opts.session_ttl_s > 0)
		and opts.session_ttl_s
		or 3600

	local sessions = make_session_store()

	svc:status('starting')
	svc:obs_log('info', { what = 'start_entered' })

	conn:retain({ 'svc', svc.name, 'announce' }, {
		role = 'ui',
		auth = 'local-session',
	})

	local function with_user_conn(principal, fn)
		local user_conn = opts.connect(principal)
		local ok, a, b, c = safe.pcall(fn, user_conn)
		pcall(function() user_conn:disconnect() end)
		if not ok then
			return nil, tostring(a)
		end
		return a, b, c
	end

	local function require_session(session_id)
		if type(session_id) ~= 'string' or session_id == '' then
			return nil, 'missing session'
		end

		local rec = sessions:get(session_id)
		if not rec then
			return nil, 'invalid or expired session'
		end

		sessions:touch(session_id, session_ttl_s)
		return rec, nil
	end

	local api = {}

	function api.login(username, password)
		local principal, err = verify_login(username, password)
		if not principal then
			svc:obs_log('warn', {
				what = 'login_failed',
				user = tostring(username),
				err  = tostring(err),
			})
			return nil, err or 'login failed'
		end

		local rec = sessions:create(principal, session_ttl_s)

		svc:obs_log('info', {
			what = 'login_ok',
			user = tostring(principal.id),
		})

		conn:publish({ 'obs', 'audit', 'ui', 'login' }, {
			user = principal.id,
			t    = now(),
		})

		return {
			session_id = rec.id,
			user = {
				id    = principal.id,
				kind  = principal.kind,
				roles = copy_plain(principal.roles or {}),
			},
			expires_at = rec.expires_at,
		}, nil
	end

	function api.logout(session_id)
		local rec = sessions:get(session_id)
		if rec then
			conn:publish({ 'obs', 'audit', 'ui', 'logout' }, {
				user = rec.principal.id,
				t    = now(),
			})
		end
		sessions:delete(session_id)
		return true, nil
	end

	function api.get_session(session_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		return {
			session_id = rec.id,
			user = {
				id    = rec.principal.id,
				kind  = rec.principal.kind,
				roles = copy_plain(rec.principal.roles or {}),
			},
			expires_at = rec.expires_at,
		}, nil
	end

	function api.config_set(session_id, service_name, data)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(service_name) ~= 'string' or service_name == '' then
			return nil, 'service_name must be a non-empty string'
		end
		if type(data) ~= 'table' or getmetatable(data) ~= nil then
			return nil, 'data must be a plain table'
		end

		local msg, rerr = with_user_conn(rec.principal, function(user_conn)
			return fibers.perform(user_conn:request_once_op(
				{ 'config', service_name, 'set' },
				{ data = copy_plain(data) }
			))
		end)

		if msg == nil then
			return nil, rerr or 'config_set failed'
		end

		local out = msg.payload
		if type(out) ~= 'table' then
			return nil, 'config_set returned non-table reply payload'
		end

		conn:publish({ 'obs', 'audit', 'ui', 'config_set' }, {
			user    = rec.principal.id,
			service = service_name,
			ok      = (out.ok == true),
			t       = now(),
		})

		return out, nil
	end

	function api.rpc_call(session_id, service_name, method_name, payload, timeout_s)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(service_name) ~= 'string' or service_name == '' then
			return nil, 'service_name must be a non-empty string'
		end
		if type(method_name) ~= 'string' or method_name == '' then
			return nil, 'method_name must be a non-empty string'
		end
		if payload ~= nil and type(payload) ~= 'table' then
			return nil, 'payload must be a table or nil'
		end

		local out, rerr = with_user_conn(rec.principal, function(user_conn)
			return user_conn:call(
				{ 'rpc', service_name, method_name },
				copy_plain(payload or {}),
				{ timeout = timeout_s or 5.0 }
			)
		end)

		if out == nil and rerr ~= nil then
			return nil, rerr
		end

		conn:publish({ 'obs', 'audit', 'ui', 'rpc_call' }, {
			user    = rec.principal.id,
			service = service_name,
			method  = method_name,
			ok      = (out ~= nil),
			t       = now(),
		})

		return out, nil
	end

	function api.health()
		return {
			service  = svc.name,
			sessions = sessions:count(),
			now      = now(),
		}, nil
	end

	-- Transport hook.
	--
	-- The intended next layer is something like:
	--   services.ui.http_transport.run(svc, api, opts)
	--
	-- For this first step we keep transport out of the service logic.
	if type(opts.run_http) ~= 'function' then
		svc:status('failed', { reason = 'missing run_http transport callback' })
		error('ui: opts.run_http(svc, api, opts) is required for this skeleton', 0)
	end

	-- Keep the session store tidy in the background.
	fibers.spawn(function()
		while true do
			sessions:prune()
			fibers.perform(require('fibers.sleep').sleep_op(30.0))
		end
	end)

	svc:status('running')
	svc:obs_log('info', { what = 'ui_ready' })

	-- Delegate to the transport layer. This is expected not to return under
	-- normal operation.
	return opts.run_http(svc, api, opts)
end

return M
